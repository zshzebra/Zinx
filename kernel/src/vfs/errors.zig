pub const VFSError = error{
    // Path errors
    NotAbsolutePath,
    PathNotFound,
    InvalidPath,

    // Node type errors
    NotAFile,
    NotADirectory,
    IsADirectory,
    IsAFile,

    // Mount errors
    AlreadyMounted,
    NotMounted,
    MountPointNotFound,

    // Filesystem errors
    UnknownFilesystem,
    FilesystemCorrupted,
    InitializationFailed,

    // I/O errors
    ReadError,
    WriteError,
    SeekError,
    EndOfFile,
    InvalidSeekPosition,
    ReadFailed,
    EndOfStream,

    // Resource errors
    OutOfMemory,
    TooManyOpenFiles,
    NoSpaceLeft,

    // Permission/existence errors
    AlreadyExists,
    DoesNotExist,
    NotEmpty,

    // General errors
    Unsupported,
    InvalidArgument,
};
