require 'set'
require 'forwardable'
require 'pathname'

class DirIterator
  attr_reader :path

  class Error < StandardError
  end

  class Filters
    # files first, then directories
    def self.files_first(paths)
      preserve_sort_by(paths) { |ea| ea.file? ? -1 : 1 }
    end

    # directories first, then files
    def self.directories_first(paths)
      preserve_sort_by(paths) { |ea| ea.directory? ? -1 : 1 }
    end

    # order by the mtime of each file. Oldest files first.
    def self.order_by_mtime_asc(paths)
      preserve_sort_by(paths) { |ea| ea.mtime.to_i }
    end

    # reverse order by the mtime of each file. Newest files first.
    def self.order_by_mtime_desc(paths)
      preserve_sort_by(paths) { |ea| -1 * ea.mtime.to_i }
    end

    # order by the name of each file.
    def self.order_by_name(paths)
      preserve_sort_by(paths) { |ea| ea.basename.to_s }
    end

    # reverse the order of the sort
    def self.reverse(paths)
      paths.reverse
    end

    def self.preserve_sort_by(array, &block)
      ea_to_index = Hash[array.zip((0..array.size-1).to_a)]
      array.sort_by do |ea|
        [yield(ea), ea_to_index[ea]]
      end
    end
  end

  class Iterator
    extend Forwardable
    def_delegators :@configuration, :filter_paths
    attr_reader :path

    def initialize(diriterator, path, parent_iterator = nil)
      @configuration = diriterator
      @path = Path.clean(path).freeze
      @parent = parent_iterator
      @visited = []
    end

    def each(block)
    	#puts "each 1"
    	while nxt = next_file
	   #puts "Next: #{nxt}"
	   block.call nxt
	end
    	#puts "each 2"
    end

    def peek
      return nil unless @path.exist?

      if @sub_iter
        nxt = @sub_iter.peek
        return nxt unless nxt.nil?
        #mark_visited(@sub_iter.path)
        @sub_iter = nil
      end

      nxt = next_visitable_child
      return nil if nxt.nil?

      if nxt.directory?
        @sub_iter = Iterator.new(@configuration, nxt, self)
        self.peek
      else
        #mark_visited(nxt)
        nxt
      end
    end

    def next
      return nil unless @path.exist?

      if @sub_iter
        nxt = @sub_iter.next
        return nxt unless nxt.nil?
        mark_visited(@sub_iter.path)
        @sub_iter = nil
      end

      nxt = next_visitable_child
      return nil if nxt.nil?

      if nxt.directory?
        @sub_iter = Iterator.new(@configuration, nxt, self)
        self.next
      else
        mark_visited(nxt)
        nxt
      end
    end

    def prev
      return nil unless @path.exist?

      if @sub_iter
        prv = @sub_iter.prev
        return prv unless prv.nil?
        mark_unvisited(@sub_iter.path)
        @sub_iter = nil
      end

      mark_unvisited(prv)
    end

    alias :next_file :next
    alias :prev_file :prev

    #def next_file
      #return nil unless @path.exist?

      #if @sub_iter
        #nxt = @sub_iter.next_file
        #return nxt unless nxt.nil?
        #mark_visited(@sub_iter.path)
        #@sub_iter = nil
      #end

      #nxt = next_visitable_child
      #return nil if nxt.nil?

      #if nxt.directory?
        #@sub_iter = Iterator.new(@configuration, nxt, self)
        #self.next_file
      #else
        #mark_visited(nxt)
        #nxt
      #end
    #end

    private

    def children
      # If someone touches the directory while we iterate, redo the @children.
      if @children.nil? || @mtime != @path.mtime || @ctime != @path.ctime
        puts "Scanning #{@path}"
        @mtime = @path.mtime
        @ctime = @path.ctime
        @children = filter_paths(@path.children)
      end
      @children
    end

    def next_visitable_child
      children.detect { |ea| !@visited.include?(Path.base(ea)) }
    end

    def mark_visited(path)
      @visited << Path.base(path)
    end

    def mark_unvisited(path)
      @visited.pop
    end
  end

  class Path
    def self.clean(path)
      path = Pathname.new(path) unless path.is_a? Pathname
      path = path.expand_path unless path.absolute?
      path
    end

    def self.base(path)
      path.basename.to_s
    end

    def self.clean_array(array)
      array.map { |ea| clean(ea) }
    end

    def self.base_array(array)
      array.map { |ea| base(ea) }
    end

    def self.hidden?(path)
      base(path).start_with?('.')
    end
  end

  def initialize(path)
    @path = Path.clean(path)
    @flags = 0
  end

  # These are File.fnmatch patterns, and are only applied to files, not directories.
  # If any pattern matches, it will be returned by Iterator#next_file.
  # (see File.fnmatch?)
  def patterns
    @patterns ||= []
  end

  def add_patterns(patterns)
    self.patterns += patterns
  end

  def add_pattern(pattern)
    self.patterns << pattern
  end

  def add_extension(extension)
    add_pattern "*#{normalize_extension(extension)}"
  end

  def add_extensions(extensions)
    extensions.each { |ea| add_extension(ea) }
  end

  # Should patterns be interpreted in a case-sensitive manner? The default is case sensitive,
  # but if your local filesystem is not case sensitive, this flag is a no-op.
  def case_sensitive!
    @flags &= ~File::FNM_CASEFOLD
  end

  def case_insensitive!
    @flags |= File::FNM_CASEFOLD
  end

  def ignore_case?
    (@flags & File::FNM_CASEFOLD) > 0
  end

  # Should we traverse hidden directories and files? (default is to skip files that start
  # with a '.')
  def include_hidden!
    @flags |= File::FNM_DOTMATCH
  end

  def exclude_hidden!
    @flags &= ~File::FNM_DOTMATCH
  end

  def include_hidden?
    (@flags & File::FNM_DOTMATCH) > 0
  end

  def filters_class
    @filters_class ||= Filters
  end

  def filters_class=(new_filters_class)
    raise Error unless new_filters_class.is_a? Class
    filters.each { |ea| new_filters_class.method(ea) } # verify the filters class has those methods defined
    @filters_class = new_filters_class
  end

  # Accepts symbols whose names are class methods on Finder::Filters.
  #
  # Filter methods receive an array of Pathname instances, and are in charge of ordering
  # and filtering the array. The returned array of pathnames will be used by the iterator.
  #
  # Those pathnames will:
  # a) have the same parent
  # b) will not have been enumerated by next() already
  # c) will satisfy the hidden flag and patterns preferences
  #
  # Note that the last filter added will be last to order the children, so it will be the
  # "primary" sort criterion.
  def add_filter(filter_symbol)
    filters << filter_symbol
  end

  def filters
    @filters ||= []
  end

  def add_filters(filter_symbols)
    filter_symbols.each { |ea| add_filter(ea) }
  end

  def iterator
    Iterator.new(self, path)
  end

  def each(&block)
    Iterator.new(self, path).each block
  end

  private

  def filter_paths(pathnames)
    viable_paths = pathnames.select { |ea| viable_path?(ea) }
    filters.inject(viable_paths) do |paths, filter_symbol|
      apply_filter(paths, filter_symbol)
    end
  end

  # Should the given file or directory be iterated over?
  def viable_path?(pathname)
    return false if !pathname.exist?
    return false if !include_hidden? && Path.hidden?(pathname)
    if patterns.empty? || pathname.directory?
      true
    else
      patterns.any? { |p| pathname.fnmatch(p, @flags) }
    end
  end

  def apply_filter(pathnames, filter_method_sym)
    filtered_pathnames = filters_class.send(filter_method_sym, pathnames.dup)
    unless filtered_pathnames.respond_to? :map
      raise Error, "#{filters_class}.#{filter_method_sym} did not return an Enumerable"
    end
    unexpected_paths = filtered_pathnames - pathnames
    unless unexpected_paths.empty?
      raise Error, "#{filters_class}.#{filter_method_sym} returned unexpected paths: #{unexpected_paths.collect { |ea| ea.to_s }.join(",")}"
    end
    filtered_pathnames
  end

  def normalize_extension(extension)
    if extension.nil? || extension.empty? || extension.start_with?(".")
      extension
    else
      ".#{extension}"
    end
  end
end

