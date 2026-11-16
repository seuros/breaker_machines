//! Thin binding to the breaker core: values, the breaker and its tickets.
//! No clock, no randomness, no guarding of blocks; the gem's Ruby runtime
//! does that on top.
mod breaker;
mod classes;
mod init;
mod names;
mod values;
