# typed: true
# frozen_string_literal: true

# Cleans a newly installed keg.
# By default:
#
# * removes `.la` files
# * removes `.tbd` files
# * removes `perllocal.pod` files
# * removes `.packlist` files
# * removes empty directories
# * sets permissions on executables
# * removes unresolved symlinks
class Cleaner
  include Context

  # Create a cleaner for the given formula.
  def initialize(formula)
    @formula = formula
  end

  # Clean the keg of the formula.
  def clean
    ObserverPathnameExtension.reset_counts!

    # Many formulae include 'lib/charset.alias', but it is not strictly needed
    # and will conflict if more than one formula provides it
    observe_file_removal @formula.lib/"charset.alias"

    [@formula.bin, @formula.sbin, @formula.lib].each { |dir| clean_dir(dir) if dir.exist? }

    # Get rid of any info 'dir' files, so they don't conflict at the link stage
    #
    # The 'dir' files come in at least 3 locations:
    #
    # 1. 'info/dir'
    # 2. 'info/#{name}/dir'
    # 3. 'info/#{arch}/dir'
    #
    # Of these 3 only 'info/#{name}/dir' is safe to keep since the rest will
    # conflict with other formulae because they use a shared location.
    #
    # See [cleaner: recursively delete info `dir`s by gromgit · Pull Request
    # #11597][1], [emacs 28.1 bottle does not contain `dir` file · Issue
    # #100190][2], and [Keep `info/#{f.name}/dir` files in cleaner by
    # timvisher][3] for more info.
    #
    # [1]: https://github.com/Homebrew/brew/pull/11597
    # [2]: https://github.com/Homebrew/homebrew-core/issues/100190
    # [3]: https://github.com/Homebrew/brew/pull/13215
    Dir.glob(@formula.info/"**/dir").each do |file|
      info_dir_file = Pathname(file)
      next unless info_dir_file.file?
      next if info_dir_file == @formula.info/@formula.name/"dir"
      next if @formula.skip_clean?(info_dir_file)

      observe_file_removal info_dir_file
    end

    rewrite_shebangs
    remove_pip_direct_url

    prune
  end

  private

  def observe_file_removal(path)
    path.extend(ObserverPathnameExtension).unlink if path.exist?
  end

  # Removes any empty directories in the formula's prefix subtree
  # Keeps any empty directories protected by skip_clean
  # Removes any unresolved symlinks
  def prune
    dirs = []
    symlinks = []
    @formula.prefix.find do |path|
      if path == @formula.libexec || @formula.skip_clean?(path)
        Find.prune
      elsif path.symlink?
        symlinks << path
      elsif path.directory?
        dirs << path
      end
    end

    # Remove directories opposite from traversal, so that a subtree with no
    # actual files gets removed correctly.
    dirs.reverse_each do |d|
      if d.children.empty?
        puts "rmdir: #{d} (empty)" if verbose?
        d.rmdir
      end
    end

    # Remove unresolved symlinks
    symlinks.reverse_each do |s|
      s.unlink unless s.resolved_path_exists?
    end
  end

  def executable_path?(path)
    path.text_executable? || path.executable?
  end

  # Both these files are completely unnecessary to package and cause
  # pointless conflicts with other formulae. They are removed by Debian,
  # Arch & MacPorts amongst other packagers as well. The files are
  # created as part of installing any Perl module.
  PERL_BASENAMES = Set.new(%w[perllocal.pod .packlist]).freeze

  # Clean a top-level (bin, sbin, lib) directory, recursively, by fixing file
  # permissions and removing .la files, unless the files (or parent
  # directories) are protected by skip_clean.
  #
  # bin and sbin should not have any subdirectories; if either do that is
  # caught as an audit warning
  #
  # lib may have a large directory tree (see Erlang for instance), and
  # clean_dir applies cleaning rules to the entire tree
  def clean_dir(directory)
    directory.find do |path|
      path.extend(ObserverPathnameExtension)

      Find.prune if @formula.skip_clean? path

      next if path.directory?

      if path.extname == ".la" || path.extname == ".tbd" || PERL_BASENAMES.include?(path.basename.to_s)
        path.unlink
      elsif path.symlink?
        # Skip it.
      else
        # Set permissions for executables and non-executables
        perms = if executable_path?(path)
          0555
        else
          0444
        end
        if debug?
          old_perms = path.stat.mode & 0777
          odebug "Fixing #{path} permissions from #{old_perms.to_s(8)} to #{perms.to_s(8)}" if perms != old_perms
        end
        path.chmod perms
      end
    end
  end

  def rewrite_shebangs
    require "language/perl"
    require "utils/shebang"

    basepath = @formula.prefix.realpath
    basepath.find do |path|
      Find.prune if @formula.skip_clean? path

      next if path.directory? || path.symlink?

      begin
        Utils::Shebang.rewrite_shebang Language::Perl::Shebang.detected_perl_shebang(@formula), path
      rescue ShebangDetectionError
        break
      end
    end
  end

  # Remove non-reproducible pip direct_url.json which records the /tmp build directory
  sig { void }
  def remove_pip_direct_url
    basepath = @formula.prefix.realpath
    basepath.find do |path|
      Find.prune if @formula.skip_clean?(path)

      next if path.directory? || path.symlink?
      next if path.basename.to_s != "direct_url.json"
      next if path.parent.extname != ".dist-info"

      odebug "Removing #{path}"
      path.unlink

      record = path.parent/"RECORD"
      next unless record.file?

      odebug "Modifying #{record}"
      @formula.inreplace record, %r{^.*/direct_url\.json,.*$\n?}, "", false
    end
  end
end

require "extend/os/cleaner"
