class CodingHarnessError(Exception):
    """Base error whose class name is stable in the result protocol."""


class DaemonUnavailableError(CodingHarnessError):
    pass


class DaemonProtocolError(CodingHarnessError):
    pass


class ResponseTooLargeError(CodingHarnessError):
    pass


class ArgumentValidationError(CodingHarnessError):
    pass


class CallBudgetExceeded(CodingHarnessError):
    pass


class ExecutionTimeout(CodingHarnessError):
    pass


class WorkerProtocolError(CodingHarnessError):
    pass


class ArtifactBudgetExceeded(CodingHarnessError):
    pass


class MemoryBudgetExceeded(CodingHarnessError):
    pass
