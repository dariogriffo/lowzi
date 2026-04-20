/// Project-wide error sets with stable names.
/// Every public function returning an error returns one of these (or a subset).
pub const CliError = error{ UnknownFlag, MissingValue, InvalidValue };
pub const PathError = error{NoHomeDir};
pub const ChannelError = error{Closed};
pub const NetworkError = error{ Timeout, ConnectionLost, HttpStatus };
pub const DecodeError = error{ UnsupportedFormat, Corrupt };
