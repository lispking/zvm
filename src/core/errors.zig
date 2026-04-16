//! Domain-specific error definitions for zvm.
//! All zvm commands use this centralized error set for consistent error handling.

const std = @import("std");

/// Comprehensive error set covering all zvm failure modes.
pub const ZvmError = error{
    /// The requested bundle/tarball path is missing in the version map.
    MissingBundlePath,
    /// The current OS/architecture combination is not supported.
    UnsupportedSystem,
    /// The requested Zig version does not exist or is not available.
    UnsupportedVersion,
    /// The ZVM_INSTALL environment variable is not set.
    MissingInstallPathEnv,
    /// Self-upgrade failed (download, extract, or replace).
    FailedUpgrade,
    /// The version map JSON is malformed or missing required fields.
    InvalidVersionMap,
    /// User provided invalid input (bad argument, unknown command, etc.).
    InvalidInput,
    /// HTTP download failed (network error, non-200 status, etc.).
    DownloadFailed,
    /// No compatible ZLS version found for the installed Zig version.
    NoZlsVersion,
    /// Version information is missing from the version map entry.
    MissingVersionInfo,
    /// SHA256 checksum is missing for the requested version/platform.
    MissingShasum,
    /// The requested Zig version is not installed locally.
    ZigNotInstalled,
    /// A required argument was not provided.
    MissingArgument,
    /// An invalid alias was specified.
    InvalidAlias,
    /// Settings file could not be read or written.
    NoSettings,
    /// File checksum does not match the expected SHA256 hash.
    ShasumMismatch,
    /// Archive extraction failed (corrupt file, unsupported format, etc.).
    ExtractionFailed,
    /// The requested Zig version is not installed.
    VersionNotInstalled,
    /// The requested Zig version is already installed (use --force to override).
    VersionAlreadyInstalled,
    /// The provided URL is malformed or invalid.
    InvalidUrl,
    /// An external command (tar, chmod, etc.) failed.
    CommandFailed,
    /// The requested file was not found.
    FileNotFound,
};
