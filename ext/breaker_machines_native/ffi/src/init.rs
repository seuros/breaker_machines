//! Private native entry point.
use magnus::{Error, Ruby, function, method, prelude::*};
use matryona_machines::ruby::{Class, Symbols};

use crate::breaker::{Breaker, Ticket};
use crate::{classes, names, values};

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("BreakerMachines")?;
    let ticket = module.define_class("Ticket", ruby.class_object())?;
    Ticket::define(ticket)?;
    classes::resolve(ruby, module, ticket)?;
    module.const_set("REFUSALS", names::Refusals::every(ruby))?;
    module.const_set("STATES", names::States::every(ruby))?;
    module.const_set("OUTCOMES", names::Outcomes::every(ruby))?;
    let validate = function!(values::validate_threshold, 3);
    module.define_singleton_method("native_threshold", validate)?;
    let validate = function!(values::validate_recovery, 4);
    module.define_singleton_method("native_recovery", validate)?;
    let validate = function!(values::validate_policy, 4);
    module.define_singleton_method("native_policy", validate)?;
    let validate = function!(values::validate_status, 3);
    module.define_singleton_method("native_status", validate)?;
    let validate = function!(values::validate_event, 3);
    module.define_singleton_method("native_event", validate)?;

    let class = module.define_class("Breaker", ruby.class_object())?;
    class.undef_default_alloc_func();
    class.define_singleton_method("native_new", function!(Breaker::new, 1))?;
    class.define_singleton_method("native_with_scope", function!(Breaker::with_scope, 2))?;
    class.define_method("admit", method!(Breaker::admit, 1))?;
    class.define_method("complete", method!(Breaker::complete, 4))?;
    class.define_method("abandon", method!(Breaker::abandon, 1))?;
    class.define_method("observe", method!(Breaker::observe, 4))?;
    class.define_method("force_open", method!(Breaker::force_open, 2))?;
    class.define_method("force_close", method!(Breaker::force_close, 0))?;
    class.define_method("reset", method!(Breaker::reset, 0))?;
    class.define_method("status", method!(Breaker::status, 0))?;
    class.define_method("adopt", method!(Breaker::adopt, 1))?;
    class.define_method("state", method!(Breaker::state, 0))?;
    class.define_method("policy", method!(Breaker::policy, 0))?;
    class.define_method("latest", method!(Breaker::latest, 0))?;
    class.define_method("opened_at", method!(Breaker::opened_at, 0))?;
    class.define_method("retry_at", method!(Breaker::retry_at, 0))?;
    class.define_method("retry_after", method!(Breaker::retry_after, 1))?;
    class.define_method("failures", method!(Breaker::failures, 1))?;
    class.define_method("successes", method!(Breaker::successes, 1))?;
    let attempts = method!(Breaker::half_open_attempts, 0);
    class.define_method("half_open_attempts", attempts)?;
    let successes = method!(Breaker::half_open_successes, 0);
    class.define_method("half_open_successes", successes)?;
    class.define_method("outstanding", method!(Breaker::outstanding, 0))?;
    class.define_method("scope", method!(Breaker::scope, 0))?;
    class.define_method("events", method!(Breaker::events, 1))?;
    // `native_new` answers a Breaker and every method reads one: its class
    // is fixed now, like the ticket's, so none of them runs Ruby to find it.
    Class::pin_wrapped::<Breaker>(ruby, class).map(drop)
}
