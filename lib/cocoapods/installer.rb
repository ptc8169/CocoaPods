module Pod

  # The Installer is responsible of taking a Podfile and transform it in the
  # Pods libraries. It also integrates the user project so the Pods
  # libraries can be used out of the box.
  #
  # The Installer is capable of doing incremental updates to an existing Pod
  # installation.
  #
  # The Installer gets the information that it needs mainly from 3 files:
  #
  #   - Podfile: The specification written by the user that contains
  #     information about targets and Pods.
  #   - Podfile.lock: Contains information about the pods that were previously
  #     installed and in concert with the Podfile provides information about
  #     which specific version of a Pod should be installed. This file is
  #     ignored in update mode.
  #   - Manifest.lock: A file contained in the Pods folder that keeps track of
  #     the pods installed in the local machine. This files is used once the
  #     exact versions of the Pods has been computed to detect if that version
  #     is already installed. This file is not intended to be kept under source
  #     control and is a copy of the Podfile.lock.
  #
  # The Installer is designed to work in environments where the Podfile folder
  # is under source control and environments where it is not. The rest of the
  # files, like the user project and the workspace are assumed to be under
  # source control.
  #
  class Installer
    autoload :TargetInstaller,       'cocoapods/installer/target_installer'
    autoload :UserProjectIntegrator, 'cocoapods/installer/user_project_integrator'

    include Config::Mixin

    # @return [Sandbox] The sandbox where the Pods should be installed.
    #
    attr_reader :sandbox

    # @return [Podfile] The Podfile specification that contains the information
    #         of the Pods that should be installed.
    #
    attr_reader :podfile

    # @return [Lockfile] The Lockfile that stores the information about the
    #         Pods previously installed on any machine.
    #
    attr_reader :lockfile

    # @param  [Sandbox]  sandbox     @see sandbox
    # @param  [Podfile]  podfile     @see podfile
    # @param  [Lockfile] lockfile    @see lockfile
    #
    def initialize(sandbox, podfile, lockfile = nil)
      @sandbox     =  sandbox
      @podfile     =  podfile
      @lockfile    =  lockfile
    end

    # @return [Bool] Whether the installer is in update mode. In update mode
    #         the contents of the Lockfile are not taken into account for
    #         deciding what Pods to install.
    #
    attr_accessor :update_mode

    # Installs the Pods.
    #
    # The installation process of is mostly linear with few minor complications
    # to keep in mind:
    #
    # - The stored podspecs need to be cleaned before the resolution step
    #   otherwise the sandbox might return an old podspec and not download
    #   the new one from an external source.
    # - The resolver might trigger the download of Pods from external sources
    #   necessary to retrieve their podspec (unless it is instructed not to
    #   do it).
    #
    # @note   The order of the steps is very important and should be changed
    #         carefully.
    #
    # @return [void]
    #
    def install!
      analyze
      generate_local_pods
      generate_names_of_pods_to_install

      prepare_for_legacy_compatibility
      clean_global_support_files
      clean_removed_pods
      clean_pods_to_install
      install_dependencies
      install_targets
      write_lockfiles
      integrate_user_project
    end

    #-------------------------------------------------------------------------#

    # @!group Installation products

    public

    # @return [Analyzer] the analyzer which provides the information about what
    #         needs to be installed.
    #
    attr_reader :analyzer

    # @return [Pod::Project] the `Pods/Pods.xcodeproj` project.
    #
    attr_reader :pods_project

    # @return [Array<TargetInstaller>]
    #
    attr_reader :target_installers

    # @return [Hash{TargetDefinition => Array<LocalPod>}] The local pod
    #         instances grouped by target.
    #
    attr_reader :local_pods_by_target

    # @return [Array<LocalPod>] The list of LocalPod instances for each
    #         dependency sorted by name.
    #
    attr_reader :local_pods

    # @return [Array<String>] The Pods that should be installed.
    #
    attr_reader :names_of_pods_to_install

    #-------------------------------------------------------------------------#

    # @!group Installation steps

    private

    def analyze
      @analyzer = Analyzer.new(sandbox, podfile, lockfile)
      @analyzer.update_mode = update_mode
      @analyzer.analyze
    end

    # Converts the specifications produced by the Resolver in local pods.
    #
    # The LocalPod class is responsible to handle the concrete representation
    # of a specification in the {Sandbox}.
    #
    # @return [void]
    #
    # @todo [#535] LocalPods should resolve the specification passing the
    #       library.
    #
    # @todo Why the local pods are generated by the sandbox? I guess because
    #       some where pre-downloaded? However the sandbox should just store
    #       the name of those Pods.
    #
    def generate_local_pods
      @local_pods_by_target = {}
      analyzer.specs_by_target.each do |target_definition, specs|
        @local_pods_by_target[target_definition] = specs.map do |spec|
          if spec.local?
            sandbox.locally_sourced_pod_for_spec(spec, target_definition.platform)
          else
            sandbox.local_pod_for_spec(spec, target_definition.platform)
          end
        end.uniq.compact
      end

      @local_pods = local_pods_by_target.values.flatten.uniq.sort_by { |pod| pod.name.downcase }
    end

    # Computes the list of the Pods that should be installed or reinstalled in
    # the {Sandbox}.
    #
    # The pods to install are identified as the Pods that don't exist in the
    # sandbox or the Pods whose version differs from the one of the lockfile.
    #
    # @note   In update mode specs originating from external dependencies and
    #         or from head sources are always reinstalled.
    #
    # @return [void]
    #
    # @todo [#534] Detect if the folder of a Pod is empty (even if it exits).
    #
    # @todo There could be issues with the current implementation regarding
    #       external specs.
    #
    def generate_names_of_pods_to_install
      changed_pods_names = []
      if update_mode
        changed_pods_names += pods.select do |pods|
          pod.top_specification.version.head? ||
            resolver.pods_from_external_sources.include?(pod.name)
        end
      end
      changed_pods_names += analyzer.sandbox_state.added + analyzer.sandbox_state.changed
      not_existing_pods = local_pods.reject { |pod| pod.exists? }
      @names_of_pods_to_install = (changed_pods_names + not_existing_pods.map(&:name)).uniq
    end

    # Prepares the Pods folder in order to be compatible with the most recent
    # version of CocoaPods.
    #
    # @return [void]
    #
    def prepare_for_legacy_compatibility
      # move_target_support_files_if_needed
      # move_Local_Podspecs_to_Podspecs_if_needed
      # move_pods_to_sources_folder_if_needed
    end

    # @return [void] In this step we clean all the folders that will be
    #         regenerated from scratch and any file which might not be
    #         overwritten.
    #
    # @todo Clean the podspecs of all the pods that aren't unchanged so the
    #       resolution process doesn't get confused by them.
    #
    def clean_global_support_files
      sandbox.prepare_for_install
    end

    # @return [void] In this step we clean all the files related to the removed
    #         Pods.
    #
    # @todo Use the local pod implode.
    #
    # @todo [#534] Clean all the Pods folder that are not unchanged?
    #
    def clean_removed_pods
      UI.section "Removing deleted dependencies" do
        pods_deleted_from_the_lockfile.each do |pod_name|
          UI.section("Removing #{pod_name}", "-> ".red) do
            path = sandbox.root + pod_name
            path.rmtree if path.exist?
          end
        end
      end unless analyzer.sandbox_state.deleted.empty?
    end

    # @return [void] In this step we clean the files of the Pods that will be
    #         installed. We clean the files that might affect the resolution
    #         process and the files that might not be overwritten.
    #
    # @todo [#247] Clean the headers of only the pods to install.
    #
    def clean_pods_to_install

    end

    # @return [void] Install the Pods. If the resolver indicated that a Pod
    #         should be installed and it exits, it is removed an then
    #         reinstalled. In any case if the Pod doesn't exits it is
    #         installed.
    #
    def install_dependencies
      UI.section "Downloading dependencies" do
        local_pods.each do |pod|
          if names_of_pods_to_install.include?(pod.name)
            UI.section("Installing #{pod}".green, "-> ".green) do
              install_local_pod(pod)
            end
          else
            UI.section("Using #{pod}", "-> ".green)
          end
        end
      end
    end

    # @return [void] Downloads, clean and generates the documentation of a pod.
    #
    # @note  The docs need to be generated before cleaning because the
    #        documentation is created for all the subspecs.
    #
    # @note  In this step we clean also the Pods that have been pre-downloaded
    #        in AbstractExternalSource#specification_from_sandbox.
    #
    # @todo  [#529] Podspecs should not be preserved anymore to prevent user
    #        confusion. Currently we are copying the ones form external sources
    #        in `Local Podspecs` and this feature is not needed anymore.
    #        I think that copying all the used podspecs would be helpful for
    #        debugging.
    #
    def install_local_pod(pod)
      unless pod.downloaded?
        pod.implode
        download_pod(pod)
      end
      generate_docs_if_needed(pod)
      pod.clean! if config.clean?
    end

    # Downloads a Pod forcing the `bleeding edge' version if requested.
    #
    # @todo store the source of non specific downloads in the lockfile.
    #
    # @return [void]
    #
    def download_pod(pod)
      downloader = Downloader.for_target(pod.root, pod.top_specification.source.dup)
      downloader.cache_root = "~/Library/Caches/CocoaPods"
      downloader.max_cache_size = 500
      downloader.agressive_cache = config.agressive_cache?

      if pod.top_specification.version.head?
        downloader.download_head
        specific_source = downloader.checkout_options
      else
        downloader.download
        specific_source = downloader.checkout_options if downloader.specific_options?
      end
      pod.downloaded = true
      if specific_source
        # store the specific source
      end
    end

    # Generates the documentation of a Pod unless it exists for a given
    # version.
    #
    # @return [void]
    #
    def generate_docs_if_needed(pod)
      doc_generator = Generator::Documentation.new(pod)
      if ( config.generate_docs? && !doc_generator.already_installed? )
        UI.section " > Installing documentation"
        doc_generator.generate(config.doc_install?)
      else
        UI.section " > Using existing documentation"
      end
    end

    # Creates and populates the targets of the pods project.
    #
    # @note   Post install hooks run _before_ saving of project, so that they
    #         can alter it before it is written to the disk.
    #
    # @return [void]
    #
    def install_targets
      UI.section "Generating support files" do
        prepare_pods_project
        generate_target_installers
        add_source_files_to_pods_project
        run_pre_install_hooks
        generate_target_support_files
        run_post_install_hooks
        write_pod_project
      end
    end

    # Creates the Pods project from scratch if it doesn't exists.
    #
    # @todo   Clean and modify the project if it exists.
    #
    # @return [void]
    #
    def prepare_pods_project
      UI.message "- Creating Pods project" do
        @pods_project = Pod::Project.new(config.sandbox)
        if config.podfile_path.exist?
          @pods_project.add_podfile(config.podfile_path)
        end
      end
    end

    # Creates a target installer for each definition not empty.
    #
    # @return [void]
    #
    def generate_target_installers
      @target_installers = podfile.target_definitions.values.map do |definition|
        pods_for_target = local_pods_by_target[definition]
        libray = analyzer.libraries.find {|l| l.target_definition == definition }
        TargetInstaller.new(pods_project, libray, pods_for_target) unless definition.empty?
      end.compact
    end

    # Adds the source files of the Pods to the Pods project.
    #
    # The source files are grouped by Pod and in turn by subspec
    # (recursively). Pods are generally added to the `Pods` group, however, if
    # they have a local source they are added to the `Local Pods` group.
    #
    # @return [void]
    #
    # @todo   Clean the groups of the deleted Pods and add only the Pods that
    #         should be installed.
    # @todo   [#588] Add file references for the resources of the Pods as well
    #         so they are visible for the user.
    #
    def add_source_files_to_pods_project
      UI.message "- Adding Pods files to Pods project" do
        local_pods.each { |p| p.add_file_references_to_project(pods_project) }
        local_pods.each { |p| p.link_headers }
      end
    end

    # Runs the pre install hooks of the installed specs and of the Podfile.
    #
    # @todo   Run the hooks only for the installed pods.
    #
    # @todo   Print a message with the names of the specs.
    #
    # @return [void]
    #
    def run_pre_install_hooks
      UI.message "- Running pre install hooks" do
        local_pods_by_target.each do |target_definition, pods|
          pods.each do |pod|
            pod.top_specification.pre_install!(pod, target_definition)
          end
        end
        @podfile.pre_install!(self)
      end
    end

    # Runs the post install hooks of the installed specs and of the Podfile.
    #
    # @todo   Run the hooks only for the installed pods.
    #
    # @todo   Print a message with the names of the specs.
    #
    # @return [void]
    #
    def run_post_install_hooks
      UI.message "- Running post install hooks" do
        target_installers.each do |target_installer|
          target_installer.library.specs.each do |spec|
            spec.post_install!(target_installer)
          end
        end
        @podfile.post_install!(self)
      end
    end

    # Installs the targets of the Pods projects and generates their support
    # files.
    #
    # @todo Move the acknowledgements to the target installer?
    #
    def generate_target_support_files
      UI.message"- Installing targets" do
        target_installers.each do |target_installer|
          pods_for_target = local_pods_by_target[target_installer.library.target_definition]
          target_installer.install!
          acknowledgements_path = target_installer.library.acknowledgements_path
          Generator::Acknowledgements.new(target_installer.library.target_definition,
                                          pods_for_target).save_as(acknowledgements_path)
          generate_dummy_source(target_installer)
        end
      end
    end

    # Generates a dummy source file for each target so libraries that contain
    # only categories build.
    #
    # @todo Move to the target installer?
    #
    def generate_dummy_source(target_installer)
      class_name_identifier = target_installer.library.label
      dummy_source = Generator::DummySource.new(class_name_identifier)
      filename = "#{dummy_source.class_name}.m"
      pathname = Pathname.new(sandbox.root + filename)
      dummy_source.save_as(pathname)
      file = pods_project.new_file(filename, "Targets Support Files")
      target_installer.target.source_build_phase.add_file_reference(file)
    end

    # Writes the Pods project to the disk.
    #
    # @return [void]
    #
    def write_pod_project
      UI.message "- Writing Xcode project file to #{UI.path @sandbox.project_path}" do
        pods_project.save_as(@sandbox.project_path)
      end
    end

    # Writes the Podfile and the {Sandbox} lock files.
    #
    # @return [void]
    #
    def write_lockfiles
      @lockfile = Lockfile.generate(podfile, analyzer.specifications)

      UI.message "- Writing Lockfile in #{UI.path config.lockfile_path}" do
        @lockfile.write_to_disk(config.lockfile_path)
      end

      UI.message "- Writing Manifest in #{UI.path sandbox.manifest_path}" do
        @lockfile.write_to_disk(sandbox.manifest_path)
      end
    end

    # Integrates the user project.
    #
    # The following actions are performed:
    #   - libraries are added.
    #   - the build script are added.
    #   - the xcconfig files are set.
    #
    # @return [void]
    #
    # @todo   [#397] The libraries should be cleaned and the re-added on every
    #         installation. Maybe a clean_user_project phase should be added.
    #         In any case it appears to be a good idea store target definition
    #         information in the lockfile.
    #
    # @todo   [#588] The resources should be added through a build phase
    #         instead of using a script.
    #
    def integrate_user_project
      return unless config.integrate_targets?
      UserProjectIntegrator.new(podfile, pods_project, config.project_root, analyzer.libraries).integrate!
    end
  end
end
