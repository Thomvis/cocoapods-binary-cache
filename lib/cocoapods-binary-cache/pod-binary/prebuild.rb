require "fileutils"
require_relative "../prebuild_output/output"
require_relative "../helper/lockfile"
require_relative "../helper/prebuild_order"
require_relative "helper/target_checker"
require_relative "helper/build"

module Pod
  class PrebuildInstaller < Installer # rubocop:disable Metrics/ClassLength
    attr_reader :lockfile_wrapper

    def initialize(options)
      super(options[:sandbox], options[:podfile], options[:lockfile])
      @cache_validation = options[:cache_validation]
      @lockfile_wrapper = lockfile && PodPrebuild::Lockfile.new(lockfile)
    end

    def run_code_gen!(targets)
      return if PodPrebuild.config.prebuild_code_gen.nil?

      Pod::UI.title("Running code generation...") do
        PodPrebuild.config.prebuild_code_gen.call(self, targets)
      end
    end

    def prebuild_output
      @prebuild_output ||= PodPrebuild::Output.new(sandbox)
    end

    def targets_to_prebuild
      to_build = PodPrebuild.config.targets_to_prebuild_from_cli
      if to_build.empty?
        to_build = PodPrebuild.config.prebuild_all_pods? ? @cache_validation.all : @cache_validation.missed
      end
      pod_targets.select { |target| to_build.include?(target.name) }
    end

    def prebuild_scheme_name
      "_Prebuild"
    end

    def create_prebuild_scheme(names)
      Pod::UI.puts "Create a scheme '#{prebuild_scheme_name}' to prebuild #{names.count} given targets"

      scheme = Xcodeproj::XCScheme.new
      pods_project.targets
        .select { |t| names.include?(t.name) }
        .each { |t| scheme.add_build_target(t) }
      scheme.test_action.code_coverage_enabled = "YES"
      scheme.save_as(pods_project.path, prebuild_scheme_name, false)
    end

    def prebuild_frameworks!
      sandbox_path = sandbox.root
      targets = targets_to_prebuild
      Pod::UI.puts "Prebuild frameworks (total #{targets.count}): #{targets.map(&:name)}".magenta
      return if targets.empty?

      create_prebuild_scheme(targets.map(&:name))
      run_code_gen!(targets)

      Pod::Prebuild.remove_build_dir(sandbox_path)
      Pod::Prebuild.build(
        sandbox: sandbox_path,
        scheme: prebuild_scheme_name,
        targets: targets,
        configuration: PodPrebuild.config.prebuild_config,
        output_path: sandbox.generate_framework_path,
        bitcode_enabled: PodPrebuild.config.bitcode_enabled?,
        device_build_enabled: PodPrebuild.config.device_build_enabled?,
        disable_dsym: PodPrebuild.config.disable_dsym?,
        args: PodPrebuild.config.build_args
      )
      Pod::Prebuild.remove_build_dir(sandbox_path)

      targets.each do |target|
        collect_metadata(target, sandbox.framework_folder_path_for_target_name(target.name))
      end

      # copy vendored libraries and frameworks
      targets.each do |target|
        root_path = sandbox.pod_dir(target.name)
        target_folder = sandbox.framework_folder_path_for_target_name(target.name)

        # If target shouldn't build, we copy all the original files
        # This is for target with only .a and .h files
        unless target.should_build?
          FileUtils.cp_r(root_path, target_folder, :remove_destination => true)
          next
        end

        target.spec_consumers.each do |consumer|
          file_accessor = Sandbox::FileAccessor.new(root_path, consumer)
          lib_paths = file_accessor.vendored_frameworks || []
          lib_paths += file_accessor.vendored_libraries
          # @TODO dSYM files
          lib_paths.each do |lib_path|
            relative = lib_path.relative_path_from(root_path)
            destination = target_folder + relative
            destination.dirname.mkpath unless destination.dirname.exist?
            FileUtils.cp_r(lib_path, destination, :remove_destination => true)
          end
        end
      end

      # save the pod_name for prebuild framwork in sandbox
      targets.each do |target|
        sandbox.save_pod_name_for_target target
      end

      # Remove useless files
      # remove useless pods
      all_needed_names = pod_targets.map(&:name).uniq
      useless_target_names = sandbox.exsited_framework_target_names.reject do |name|
        all_needed_names.include? name
      end
      useless_target_names.each do |name|
        Pod::UI.message "Remove: #{name}"
        path = sandbox.framework_folder_path_for_target_name(name)
        path.rmtree if path.exist?
      end

      prebuild_output.write_delta_file(
        updated: targets.map { |target| target.label.to_s },
        deleted: useless_target_names
      )
    end

    def clean_delta_file
      prebuild_output.clean_delta_file
    end

    def collect_metadata(target, output_path)
      metadata = PodPrebuild::Metadata.in_dir(output_path)
      metadata.framework_name = target.framework_name
      metadata.static_framework = target.static_framework?
      resource_paths = target.resource_paths
      metadata.resources = resource_paths.is_a?(Hash) ? resource_paths.values.flatten : resource_paths
      metadata.resource_bundles = target
        .file_accessors
        .map { |f| f.resource_bundles.keys }
        .flatten
        .map { |name| "#{name}.bundle" }
      metadata.build_settings = pods_project.targets
        .detect { |native_target| native_target.name == target.name }
        .build_configurations
        .detect { |config| config.name == PodPrebuild.config.prebuild_config }
        .build_settings
      metadata.source_hash = @lockfile_wrapper && @lockfile_wrapper.dev_pod_hash(target.name)

      # Store root path for code-coverage support later
      # TODO: update driver code-coverage logic to use path stored here
      project_root = PathUtils.remove_last_path_component(@sandbox.standard_sanbox_path.to_s)
      metadata.project_root = project_root
      metadata.save!
    end

    # patch the post install hook
    old_method2 = instance_method(:run_plugins_post_install_hooks)
    define_method(:run_plugins_post_install_hooks) do
      old_method2.bind(self).call
      prebuild_frameworks! if PodPrebuild::Env.prebuild_stage?
    end
  end
end
