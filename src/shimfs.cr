require "uuid"

class Shimfs
  VERSION = "1.0.0"

  @resource_name : String
  @is_owner : Bool
  @root : Void*
  @size : Int32

  getter resource_name
  getter is_owner
  getter size

  @[Link(ldflags: "#{__DIR__}/../imfs.o")]
  lib LibIMFS
    @[Flags]
    enum Flags : LibC::Int
      ReadOnly  = 0
      ReadWrite = 1
      Create    = 2
      Truncate  = 4
    end

    struct Conf
      max_num_fnodes : LibC::SizeT
      max_opened_files : LibC::UInt
    end

    alias IMFS = Void

    fun init = imfs_init(base : Void*, size : LibC::SizeT, conf : Conf*, format : Bool) : IMFS*
    fun mkdir = imfs_mkdir(imfs : IMFS*, path : LibC::Char*) : LibC::Int
    fun rmdir = imfs_mkdir(imfs : IMFS*, path : LibC::Char*) : LibC::Int
    fun open = imfs_open(imfs : IMFS*, path : LibC::Char*, flags : Flags) : LibC::Int
    fun close = imfs_close(imfs : IMFS*, fd : LibC::Int) : LibC::Int
    fun read = imfs_read(imfs : IMFS*, fd : LibC::Int, buffer : Void*, size : LibC::SizeT) : LibC::Int
    fun write = imfs_write(imfs : IMFS*, fd : LibC::Int, buffer : Void*, size : LibC::SizeT) : LibC::Int
  end

  lib LibCRTExt
    fun shm_open(name : LibC::Char*, oflag : LibC::Int, mode : LibC::ModeT) : LibC::Int
    fun shm_unlink(name : LibC::Char*) : LibC::Int

    # __size may be 16 bytes on 32 bit system ? Not very important
    union Semaphore
      __size : UInt8[32]
      __align : LibC::Long
    end

    # Not in crystal stdlib. require kernel >= 4.17
    # Used because imfs store absolute pointers
    MAP_FIXED_NOREPLACE = 0x100000

    fun sem_init(semaphore : Semaphore*, shared : LibC::Int, value : LibC::UInt) : LibC::Int
    fun sem_destroy(semaphore : Semaphore*) : LibC::Int
    fun sem_wait(semaphore : Semaphore*) : LibC::Int
    fun sem_post(semaphore : Semaphore*) : LibC::Int
  end

  @root : Void*
  @semaphore : LibCRTExt::Semaphore*
  @imfs : LibIMFS::IMFS*

  def address : UInt64
    @root.address
  end

  def initialize(@size)
    @is_owner = true
    @resource_name = UUID.random.to_s

    # Create a shared memory file
    shmem_fd = Shimfs.check(LibCRTExt.shm_open(@resource_name, LibC::O_CREAT | LibC::O_RDWR | LibC::O_EXCL, 0o600), "shm_open")

    # Give it a size
    Shimfs.check(LibC.ftruncate(shmem_fd, @size), "ftruncate")

    # Memory map it
    @root = LibC.mmap(nil, @size, LibC::PROT_READ | LibC::PROT_WRITE, LibC::MAP_SHARED, shmem_fd, 0)
    raise "Call to mmap failed: #{Errno.value} #{Errno.value.message}" if @root.address == -1

    # create a lock
    @semaphore = Pointer(LibCRTExt::Semaphore).new @root.address

    Shimfs.check(LibCRTExt.sem_init(@semaphore, 1, 1), "sem_init")

    # Create an IMFS
    conf = uninitialized LibIMFS::Conf
    conf.max_num_fnodes = 50
    conf.max_opened_files = 50
    @imfs = LibIMFS.init(
      base: Pointer(Void).new(@root.address + sizeof(LibCRTExt::Semaphore)),
      size: @size - sizeof(LibCRTExt::Semaphore),
      conf: pointerof(conf),
      format: true
    )

    raise "Call to imfs_init failed" if @imfs.null?
  end

  # WHY ADDRESS AND MAP_FIXED:
  # imfs store absolute pointers.
  # until it stop doing this and use relative pointer, we must ensure the
  # pointers stay valid by having the page at the same location in all process.
  def initialize(@size, @resource_name, address : Void*)
    @is_owner = false

    # Open shared memory file
    shmem_fd = Shimfs.check(LibCRTExt.shm_open(@resource_name, LibC::O_RDWR, 0o600), "shm_open")

    # Memory map it
    @root = LibC.mmap(address, @size, LibC::PROT_READ | LibC::PROT_WRITE, LibC::MAP_SHARED | LibCRTExt::MAP_FIXED_NOREPLACE, shmem_fd, 0)
    raise "Call to mmap failed: #{Errno.value} #{Errno.value.message}" if @root.address == -1

    # Get the lock
    @semaphore = Pointer(LibCRTExt::Semaphore).new @root.address

    # Create an IMFS
    conf = uninitialized LibIMFS::Conf
    conf.max_num_fnodes = 50
    conf.max_opened_files = 50
    @imfs = LibIMFS.init(
      base: Pointer(Void).new(@root.address + sizeof(LibCRTExt::Semaphore)),
      size: @size - sizeof(LibCRTExt::Semaphore),
      conf: pointerof(conf),
      format: false
    )

    raise "Call to imfs_init failed" if @imfs.null?
  end

  def finalize
    if @is_owner
      Shimfs.check(LibCRTExt.sem_destroy(@semaphore), "sem_destroy")
    end
  end

  def self.check(error : LibC::Int, name : String) : LibC::Int
    if error == -1
      raise "Call to #{name} failed: #{Errno.value} #{Errno.value.message}"
    end
    return error
  end

  def with_lock(&)
    Shimfs.check(LibCRTExt.sem_wait(@semaphore), "sem_wait")
    begin
      value = yield
    ensure
      Shimfs.check(LibCRTExt.sem_post(@semaphore), "sem_post")
    end
    return value
  end

  class IMFSIO < ::IO
    @imfs : LibIMFS::IMFS*
    @fd : LibC::Int
    @closed = false
    @shimfs : Shimfs

    def initialize(@imfs, @fd, @shimfs)
    end

    def close
      @shimfs.with_lock do
        LibIMFS.close(@imfs, @fd)
      end
      @closed = true
    end

    def read(slice : Bytes)
      @shimfs.with_lock do
        LibIMFS.read(@imfs, @fd, slice.to_unsafe, slice.size)
      end
    end

    def write(slice : Bytes) : Nil
      @shimfs.with_lock do
        LibIMFS.write(@imfs, @fd, slice.to_unsafe, slice.size)
      end
    end

    def closed? : Bool
      @closed
    end
  end

  def open(path, mode) : IMFSIO
    imfs_mode = case mode
                when "w" then LibIMFS::Flags::ReadWrite | LibIMFS::Flags::Create | LibIMFS::Flags::Truncate
                when "r" then LibIMFS::Flags::ReadOnly
                else          raise "Bad mode for opening #{path}: #{mode}"
                end

    flat_name = "/#{path.to_slice.hexstring}"

    fd = with_lock do
      LibIMFS.open(@imfs, flat_name, imfs_mode)
    end

    raise "Error while opening #{path} with mode #{mode}, imfs_open return -1" if fd == -1
    return IMFSIO.new(@imfs, fd, self)
  end
end
