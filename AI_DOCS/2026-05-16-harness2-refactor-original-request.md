Break up Test2::Harness2

Test2::Harness2 is 3k lines, and has an incredibly large collection of state attributes.

Break it into module by subsystem or substate, like extracting the scheduler.

These extractions should be to objects, not services.

Analize Test2::Harness2 and suggest how to break it into modules that the main one loads, initializes and calls.
