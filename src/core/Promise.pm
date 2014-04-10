# A promise is a synchronization mechanism for a piece of work that will
# produce a single result (keeping the promise) or fail (breaking the
# promise).
my enum PromiseStatus (:Planned(0), :Kept(1), :Broken(2));
my class X::Promise::Combinator is Exception {
    has $.combinator;
    method message() { "Can only use $!combinator to combine other Promise objects" }
}
my class X::Promise::CauseOnlyValidOnBroken is Exception {
    method message() { "Can only call cause on a broken promise" }
}
my class X::Promise::Vowed is Exception {
    method message() { "Access denied to keep/break this Promise; already vowed" }
}
my class Promise {
    has $.scheduler;
    has $.status;
    has $!result;
    has int $!vow_taken;
    has $!lock;
    has $!cond;
    has @!thens;
    
    submethod BUILD(:$!scheduler = $*SCHEDULER) {
        $!lock            := nqp::create(Lock);
        $!cond            := $!lock.condition();
        $!status           = Planned;
    }
    
    # A Promise::Vow is used to enable the right to keep/break a promise
    # to be restricted to a given "owner". Taking the Vow for a Promise
    # prevents anybody else from getting hold of it.
    class Vow { ... }
    trusts Vow;
    class Vow {
        has $.promise;
        method keep(\result) {
            $!promise!Promise::keep(result)
        }
        method break(\exception) {
            $!promise!Promise::break(exception)
        }
    }
    method vow() {
        nqp::lock($!lock);
        if $!vow_taken {
            nqp::unlock($!lock);
            X::Promise::Vowed.new.throw
        }
        my $vow := nqp::create(Vow);
        nqp::bindattr($vow, Vow, '$!promise', self);
        $!vow_taken = 1;
        nqp::unlock($!lock);
        $vow
    }

    method keep(Promise:D: \result) {
        self.vow.keep(result)
    }
    
    method !keep(\result) {
        $!lock.protect({
            $!result := result;
            $!status = Kept;
            self!schedule_thens();
            $!cond.signal_all;
        });
        $!result
    }
    
    method break(Promise:D: $result) {
        self.vow.break($result)
    }
    
    method !break($result) {
        $!lock.protect({
            $!result = nqp::istype($result, Exception)
                ?? $result
                !! X::AdHoc.new(payload => $result);
            $!status = Broken;
            self!schedule_thens();
            $!cond.signal_all;
        });
    }
    
    method !schedule_thens() {
        while @!thens {
            $!scheduler.cue(@!thens.shift, :catch(@!thens.shift))
        }
    }
    
    method result(Promise:D:) {
        # One important missing optimization here is that if the promise is
        # not yet started, then the work can be done immediately by the
        # thing that is blocking on it.
        if $!status == Planned {
            $!lock.protect({
                # Re-check planned to avoid data race.
                $!cond.wait() if $!status == Planned;
            });
        }
        if $!status == Kept {
            $!result
        }
        elsif $!status == Broken {
            $!result.throw
        }
    }
    
    method Bool(Promise:D:) {
        so $!status == any(Broken, Kept)
    }

    method cause(Promise:D:) {
        if $!status == Broken {
            $!result
        } else {
            X::Promise::CauseOnlyValidOnBroken.new.throw
        }
    }
    
    method then(Promise:D: &code) {
        nqp::lock($!lock);
        if $!status == Broken | Kept {
            # Already have the result, start immediately.
            nqp::unlock($!lock);
            Promise.start( { code(self) }, :$!scheduler);
        }
        else {
            # Create a Promise, and push 2 entries to @!thens: something that
            # starts the then code, and something that handles its exceptions.
            # They will be sent to the scheduler when this promise is kept or
            # broken.
            my $then_promise = Promise.new(:$!scheduler);
            my $vow = $then_promise.vow;
            @!thens.push({ $vow.keep(code(self)) });
            @!thens.push(-> $ex { $vow.break($ex) });
            nqp::unlock($!lock);
            $then_promise
        }
    }
    
    method start(Promise:U: &code, :$scheduler = $*SCHEDULER) {
        my $p   = Promise.new(:$scheduler);
        my $vow = $p.vow;
        $scheduler.cue(
            { $vow.keep(code()) },
            :catch(-> $ex { $vow.break($ex) }) );
        $p
    }
    
    method in(Promise:U: $seconds, :$scheduler = $*SCHEDULER) {
        my $p   = Promise.new(:$scheduler);
        my $vow = $p.vow;
        $scheduler.cue({ $vow.keep(True) }, :in($seconds));
        $p
    }
    
    method anyof(Promise:U: *@promises) {
        X::Promise::Combinator.new(combinator => 'anyof').throw
            unless @promises >>~~>> Promise;
        self!until_n_kept(@promises, 1)
    }
    
    method allof(Promise:U: *@promises) {
        X::Promise::Combinator.new(combinator => 'allof').throw
            unless @promises >>~~>> Promise;
        self!until_n_kept(@promises, @promises.elems)
    }

    method !until_n_kept(@promises, Int $n) {
        my int $c  = $n;
        my $lock  := nqp::create(Lock);
        my $p      = Promise.new;
        my $vow    = $p.vow;
        for @promises -> $cand {
            $cand.then({
                if .status == Kept {
                    if $lock.protect({ $c = $c - 1 }) == 0 {
                        $vow.keep(True)
                    }
                }
                else {
                    if $lock.protect({ my int $o = $c; $c = $c - ($n + 1); $o }) > 0 {
                        $vow.break(.cause)
                    }
                }
            })
        }
        $p
    }
}

# Schedules a piece of asynchronous work using the current scheduler, and
# returns a Promise that represents it.
sub start(&code) { Promise.start(&code) }