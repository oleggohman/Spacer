import Darwin

/// One entry of a folder, as read by `DirectoryReader`.
struct DirectoryEntry: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case directory
    case symbolicLink
    /// A regular file, or anything else that is neither a folder nor a link.
    case file
  }

  var name: String
  var kind: Kind
  var device: Int32
  var inode: UInt64
  var linkCount: UInt32
  /// Allocated bytes of all forks. Zero for folders.
  var allocatedSize: Int64
  /// True for a folder that another file system is mounted on, or an automount trigger.
  var isMountPoint: Bool
  /// The BSD file flags (`st_flags`), such as `UF_HIDDEN` or `SF_DATALESS`.
  var flags: UInt32 = 0
  /// Bytes of a clone that no other file shares (APFS), read only for files that look like
  /// clones (see `cloneID`). Nil for every other file, which counts its whole allocation.
  var privateSize: Int64? = nil
  /// Identifies the data stream of a file (APFS). A file that is not a clone has its own inode
  /// number here, and so does the original of a clone, while a clone has the ID of its original.
  /// Nil when the volume does not report it.
  var cloneID: UInt64? = nil
  /// True for a clone whose original no longer exists. The survivors keep the dead inode as their
  /// `cloneID`, and each reports the blocks they all share as not private, so the scanner counts
  /// them once per `cloneID` (see `DiskScanner`). Set only for clones.
  var isOrphanedClone = false

  /// Whether the entry is a cloud placeholder (iCloud Drive, Google Drive and other File Provider
  /// folders): its content is not on this disk, and reading it makes the provider download it.
  var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }

  /// Whether the file is a clone of another file: it has the data stream ID of its original.
  var isClone: Bool {
    kind == .file && cloneID.map { $0 != 0 && $0 != inode } ?? false
  }

  /// The bytes the file adds to its folder: a clone counts only its own bytes. This is an
  /// approximation; see the sizing rule in CLAUDE.md.
  var countedSize: Int64 {
    guard let privateSize else { return allocatedSize }
    return min(privateSize, allocatedSize)
  }
}

/// Reads folders with `getattrlistbulk(2)`, which returns the name, type, size and identity of
/// many entries per system call. This is several times faster than listing a folder with
/// `FileManager` and then asking each URL for its resource values.
enum DirectoryReader {
  private static let bufferSize = 64 * 1024

  /// The entries of the folder at `path`, or nil when it cannot be opened or read.
  /// Entries the file system reports an error for are left out.
  ///
  /// Cloud placeholders are never downloaded: while the folder is read, this thread fails on
  /// dataless content instead of waiting for the File Provider to fetch it over the network.
  static func entries(atPath path: String) -> [DirectoryEntry]? {
    let previousPolicy = getiopolicy_np(
      IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    _ = setiopolicy_np(
      IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
      IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    defer {
      if previousPolicy >= 0 {
        _ = setiopolicy_np(
          IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy)
      }
    }
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr =
      attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
      | attrgroup_t(
        truncatingIfNeeded: ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS
          | ATTR_CMN_FILEID | ATTR_CMN_ERROR)
    request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
    request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
    // Extended common attributes go in `forkattr` and need FSOPT_ATTR_CMN_EXTENDED. Volumes that
    // do not report the clone ID return nil, and the file counts its allocated size. Only the
    // clone ID is asked for here: ATTR_CMNEXT_PRIVATESIZE for every file costs about a third of
    // a full-disk scan's time, so it is read one by one for the few files that are clones.
    request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)

    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    defer { buffer.deallocate() }
    var entries: [DirectoryEntry] = []
    var readAny = false
    while true {
      let count = getattrlistbulk(
        fd, &request, buffer, bufferSize, UInt64(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
      if count < 0 {
        if errno == EINTR { continue }
        // A folder that fails on the first read is unreadable; a later failure keeps what was read.
        return readAny ? entries : nil
      }
      if count == 0 { return entries }
      readAny = true
      var record = UnsafeRawPointer(buffer)
      for _ in 0..<count {
        let length = record.loadUnaligned(as: UInt32.self)
        if var entry = parse(record) {
          if entry.isClone {
            entry.privateSize = privateSize(atPath: path + "/" + entry.name)
            if let id = entry.cloneID { entry.isOrphanedClone = !inodeExists(entry.device, id) }
          }
          entries.append(entry)
        }
        record += Int(length)
      }
    }
  }

  /// Whether the file with inode `inode` still exists on device `device`, looked up through volfs.
  /// Only used for clones. When the lookup fails for another reason than a missing file, the
  /// file is taken to exist, which keeps the clone counting only its own bytes.
  static func inodeExists(_ device: Int32, _ inode: UInt64) -> Bool {
    var info = stat()
    return stat("/.vol/\(device)/\(inode)", &info) == 0 || errno != ENOENT
  }

  /// The bytes of the file at `path` that no clone shares, or nil when they cannot be read.
  static func privateSize(atPath path: String) -> Int64? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
    request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    // Length, the returned-attributes set, then the size.
    var buffer = [UInt8](repeating: 0, count: 64)
    let result = buffer.withUnsafeMutableBytes {
      getattrlist(
        path, &request, $0.baseAddress, $0.count,
        UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
    }
    guard result == 0 else { return nil }
    return buffer.withUnsafeBytes { raw in
      let returned = raw.loadUnaligned(
        fromByteOffset: MemoryLayout<UInt32>.size, as: attribute_set_t.self)
      guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
      let offset = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
      return Int64(raw.loadUnaligned(fromByteOffset: offset, as: off_t.self))
    }
  }

  /// Parses one packed record. Attributes appear in group order (common, dir, file, then the
  /// extended common attributes in `forkattr`), in bit order within each group, and only the
  /// returned ones.
  private static func parse(_ record: UnsafeRawPointer) -> DirectoryEntry? {
    var field = record + MemoryLayout<UInt32>.size
    let returned = field.loadUnaligned(as: attribute_set_t.self)
    field += MemoryLayout<attribute_set_t>.size

    func has(_ group: attrgroup_t, _ bit: some BinaryInteger) -> Bool {
      group & attrgroup_t(truncatingIfNeeded: bit) != 0
    }
    func take<T>(_ type: T.Type) -> T {
      defer { field += MemoryLayout<T>.size }
      return field.loadUnaligned(as: T.self)
    }

    var name: String?
    if has(returned.commonattr, ATTR_CMN_NAME) {
      let reference = field.loadUnaligned(as: attrreference_t.self)
      let start = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
      name = String(cString: start)
      field += MemoryLayout<attrreference_t>.size
    }
    let device = has(returned.commonattr, ATTR_CMN_DEVID) ? take(dev_t.self) : 0
    let type = has(returned.commonattr, ATTR_CMN_OBJTYPE) ? take(fsobj_type_t.self) : nil
    let flags = has(returned.commonattr, ATTR_CMN_FLAGS) ? take(UInt32.self) : 0
    let inode = has(returned.commonattr, ATTR_CMN_FILEID) ? take(UInt64.self) : 0
    let error = has(returned.commonattr, ATTR_CMN_ERROR) ? take(UInt32.self) : 0
    let mountStatus = has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) ? take(UInt32.self) : 0
    let linkCount = has(returned.fileattr, ATTR_FILE_LINKCOUNT) ? take(UInt32.self) : 1
    let allocatedSize = has(returned.fileattr, ATTR_FILE_ALLOCSIZE) ? take(off_t.self) : 0
    let cloneID: UInt64? = has(returned.forkattr, ATTR_CMNEXT_CLONEID) ? take(UInt64.self) : nil

    guard error == 0, let name, let type else { return nil }
    let kind: DirectoryEntry.Kind
    switch type {
    case VDIR.rawValue: kind = .directory
    case VLNK.rawValue: kind = .symbolicLink
    default: kind = .file
    }
    let mountFlags = UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER)
    return DirectoryEntry(
      name: name, kind: kind, device: device, inode: inode, linkCount: linkCount,
      allocatedSize: kind == .directory ? 0 : allocatedSize,
      isMountPoint: kind == .directory && mountStatus & mountFlags != 0, flags: flags,
      cloneID: kind == .directory ? nil : cloneID)
  }
}
