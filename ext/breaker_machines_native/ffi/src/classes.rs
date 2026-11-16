//! The classes the binding checks or builds, resolved once at load and
//! pinned.
use magnus::{Error, RClass, RModule, Ruby};
use matryona_machines::ruby::Class;

use crate::breaker::Ticket;

/// Every class the binding checks or builds.
pub struct Classes {
    pub threshold: Class,
    pub recovery: Class,
    pub policy: Class,
    pub event: Class,
    pub status: Class,
    pub ticket: Class,
}

matryona_machines::registry! {
    static CLASSES: Classes = "breaker_machines";
    /// The classes resolved at load.
    pub fn classes;
}

/// Resolve the `Data` classes `breaker_machines.rb` defined before
/// requiring the extension, and pin the ticket class init defined, fixing
/// magnus's class for `Ticket` to it: no conversion runs
/// `Object.const_get` later.
pub fn resolve(ruby: &Ruby, module: RModule, ticket: RClass) -> Result<(), Error> {
    let class = |name| Class::resolve(ruby, module, name);
    let classes = Classes {
        threshold: class("Threshold")?,
        recovery: class("Recovery")?,
        policy: class("Policy")?,
        event: class("Event")?,
        status: class("Status")?,
        ticket: Class::pin_wrapped::<Ticket>(ruby, ticket)?,
    };
    CLASSES.set(ruby, classes).map(drop)
}
