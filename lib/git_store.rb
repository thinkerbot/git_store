require 'rubygems'
require 'zlib'
require 'digest/sha1'
require 'yaml'
require 'fileutils'

require 'git_store/blob'
require 'git_store/diff'
require 'git_store/tree'
require 'git_store/tag'
require 'git_store/user'
require 'git_store/pack'
require 'git_store/commit'
require 'git_store/handlers'

# GitStore implements a versioned data store based on the revision
# management system git. You can store object hierarchies as nested
# hashes, which will be mapped on the directory structure of a git
# repository.
#
# GitStore supports transactions, so that updates to the store either
# fail or succeed completely.
#
# GitStore manages concurrent access by a file locking scheme. So only
# one process can start a transaction at one time. This is implemented
# by locking the `refs/head/<branch>.lock` file, which is also respected
# by the git binary.
#
# A regular commit should be atomic by the nature of git, as the only
# critical part is writing the 40 bytes SHA1 hash of the commit object
# to the file `refs/head/<branch>`, which is done atomically by the
# operating system.
#
# So reading a repository should be always consistent in a git
# repository. The head of a branch points to a commit object, which in
# turn points to a tree object, which itself is a snapshot of the
# GitStore at commit time. All involved objects are keyed by their
# SHA1 value, so there is no chance for another process to write to
# the same files.
#
class GitStore
  include Enumerable

  TYPE_CLASS = {
    'tree' => Tree,
    'blob' => Blob,
    'commit' => Commit,
    'tag' => Tag
  }

  CLASS_TYPE = {
    Tree => 'tree',
    Blob => 'blob',
    Commit => 'commit',
    Tag => 'tag'
  }

  attr_reader :path, :index, :root, :branch, :lock_file, :head, :packs, :handler, :bare, :objects

  # Initialize a store.
  def initialize(path, branch = 'master', bare = false)
    if bare && !File.exists?("#{path}") or
        !bare && !File.exists?("#{path}/.git")
      raise ArgumentError, "first argument must be a valid Git repository: `#{path}'"
    end

    @bare    = bare
    @path    = path.chomp('/')
    @branch  = branch
    @root    = Tree.new(self)
    @packs   = {}
    @objects = {}

    @handler = {
      'yml' => YAMLHandler.new
    }
    
    @handler.default = DefaultHandler.new

    load_packs("#{git_path}/objects/pack")
    
    load
  end

  # Returns the path to the current head file.
  def head_path
    "#{git_path}/refs/heads/#{branch}"
  end

  # Returns the path to the object file for given id.
  def object_path(id)
    "#{git_path}/objects/#{ id[0...2] }/#{ id[2..39] }"
  end

  # Returns the path to the git data directory.
  def git_path
    if bare
      "#{path}"
    else
      "#{path}/.git"
    end
  end

  # Read the id of the head commit.
  #
  # Returns the object id of the last commit.
  def read_head_id
    File.read(head_path).strip if File.exists?(head_path)
  end

  # Return a handler for a given path.
  def handler_for(path)
    handler[ path.split('.').last ]
  end

  # Read an object for the specified path.
  def [](path)
    root[path]
  end

  # Write an object to the specified path.
  def []=(path, data)
    root[path] = data
  end

  # Iterate over all key-values pairs found in this store.
  def each(&block)
    root.each(&block)
  end

  # Returns all paths found in this store.
  def paths
    root.paths
  end

  # Returns all values found in this store.
  def values
    root.values
  end

  # Remove given path from store.
  def delete(path)
    root.delete(path)
  end

  # Find or create a tree object with given path.
  def tree(path)
    root.tree(path)
  end

  # Returns the store as a hash tree.
  def to_hash
    root.to_hash
  end

  # Inspect the store.
  def inspect
    "#<GitStore #{path} #{branch}>"
  end

  # Has our store been changed on disk?
  def changed?
    head.nil? or head.id != read_head_id
  end

  # Load the current head version from repository.
  def load(from_disk = false)
    if id = read_head_id
      @head = get(id)
      @root = @head.tree
    end

    load_from_disk if from_disk
  end

  def load_from_disk
    root.each_blob do |path, blob|
      file = "#{self.path}/#{path}"
      if File.file?(file)
        blob.data = File.read(file)
      end
    end
  end

  # Reload the store, if it has been changed on disk.
  def refresh!
    load if changed?
  end

  # Is there any transaction going on?
  def in_transaction?
    Thread.current['git_store_lock']
  end

  # All changes made inside a transaction are atomic. If some
  # exception occurs the transaction will be rolled back.
  #
  # Example:
  #   store.transaction { store['a'] = 'b' }
  #
  def transaction(message = "")
    start_transaction
    result = yield
    commit message

    result
  rescue
    rollback
    raise
  ensure
    finish_transaction
  end

  # Start a transaction.
  #
  # Tries to get lock on lock file, reload the this store if
  # has changed in the repository.
  def start_transaction
    file = open("#{head_path}.lock", "w")
    file.flock(File::LOCK_EX)

    Thread.current['git_store_lock'] = file

    load if changed?
  end

  # Restore the state of the store.
  #
  # Any changes made to the store are discarded.
  def rollback
    objects.clear
    load
    finish_transaction
  end

  # Finish the transaction.
  #
  # Release the lock file.
  def finish_transaction
    Thread.current['git_store_lock'].close rescue nil
    Thread.current['git_store_lock'] = nil

    File.unlink("#{head_path}.lock") rescue nil
  end

  # Write a commit object to disk and set the head of the current branch.
  #
  # Returns the commit object
  def commit(message = '', author = User.from_config, committer = author)
    root.write

    commit = Commit.new(self)
    commit.tree = root
    commit.parent << head.id if head
    commit.author = author
    commit.committer = committer
    commit.message = message
    commit.write

    open(head_path, "wb") do |file|
      file.write(commit.id)
    end

    @head = commit
  end

  # Returns a list of commits starting from head commit.
  def commits(limit = 10, start = head)
    entries = []
    current = start

    while current and entries.size < limit
      entries << current
      current = get(current.parent.first)
    end

    entries
  end

  # Get an object by its id.
  #
  # Returns a tree, blob, commit or tag object.
  def get(id)
    return nil if id.nil?

    return objects[id] if objects.has_key?(id)

    type, content = get_object(id)

    klass = TYPE_CLASS[type] or raise NotImplementedError, "type not supported: #{type}"

    objects[id] = klass.new(self, id, content)
  end

  # Save a git object to the store.
  #
  # Returns the object id.
  def put(object)
    type = CLASS_TYPE[object.class] or raise NotImplementedError, "class not supported: #{object.class}"

    id = put_object(type, object.dump)

    objects[id] = object

    id
  end

  # Returns the hash value of an object string.
  def sha(str)
    Digest::SHA1.hexdigest(str)[0, 40]
  end

  # Calculate the id for a given type and raw data string.
  def id_for(type, content)
    sha "#{type} #{content.length}\0#{content}"
  end

  # Read the raw object with the given id from the repository.
  #
  # Returns a pair of content and type of the object
  def get_object(id)
    path = object_path(id)

    if File.exists?(path)
      buf = open(path, "rb") { |f| f.read }

      raise "not a loose object: #{id}" if not legacy_loose_object?(buf)

      header, content = Zlib::Inflate.inflate(buf).split(/\0/, 2)
      type, size = header.split(/ /, 2)

      raise "bad object: #{id}" if content.length != size.to_i
    else
      content, type = get_object_from_pack(id)
    end

    return type, content
  end

  # Write a raw object to the repository.
  #
  # Returns the object id.
  def put_object(type, content)
    data = "#{type} #{content.length}\0#{content}"
    id = sha(data)
    path = object_path(id)

    unless File.exists?(path)
      FileUtils.mkpath(File.dirname(path))
      open(path, 'wb') do |f|
        f.write Zlib::Deflate.deflate(data)
      end
    end

    id
  end

  protected

  if 'String'[0].respond_to?(:ord)
    def legacy_loose_object?(buf)
      buf[0] == ?x && (((buf[0].ord << 8) + buf[1].ord) % 31 == 0)
    end
  else
    def legacy_loose_object?(buf)
      word = (buf[0] << 8) + buf[1]
      buf[0] == 0x78 && word % 31 == 0
    end
  end

  def get_object_from_pack(id)
    pack, offset = @packs[id]

    pack.parse_object(offset) if pack
  end

  def load_packs(path)
    if File.directory?(path)
      Dir.open(path) do |dir|
        entries = dir.select { |entry| entry =~ /\.pack$/i }
        entries.each do |entry|
          pack = PackStorage.new(File.join(path, entry))
          pack.each_entry do |id, offset|
            id = id.unpack("H*").first
            @packs[id] = [pack, offset]
          end
        end
      end
    end
  end

end
