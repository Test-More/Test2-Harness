# AI: Create this Logger
#
#
# What it does:
# Depends on JSONL logger, and needs to know the log file pathname. When one logger depends on another it should be constructed with: `deps => { $dep_logger_class => $dep_logger_instance, ... }` So it can ask the other loggers it depends on for info. If the logger is already initiated then a ->set_deps(...) method should be used, add an empty no-op sub for set_deps() in the role.
#
# Requires an IPC peer name to send messages to
#
# On startup sends a message to the peer with what test file is being run (both the full path and the relative) and the full path to the jsonl log file
#
# As soon as the test file transitions from passing to failing it should send a message to the peer indicaing the test job has started to fail
#
# Whenever a top level subtest starts it should send an event to the peer indicating that the subtest started
# Whenever a top level subtest completes it should send an event to the peer indicating that the subtest passed or failed
#
# When the test is done it should send a final summary with the test info, filename (relative and absolute), number of passing assertions, number of failing assertions, total assertions, a list of passing top level subtests and a lift of failing top level subtests, and thexit status. Most if not all of this should already be tracked by the auditor
#
# To make this work the auditor will have to be initialized before the loggers, and passed into the loggers. This logger should throw an exception if it is used without a logger. Loggers should probably get a set_auditor method, so put a no-op stub of set_auditor into the logger role.
#
# At the moment nothing should use this logger by default, it must be requested by something else later.
