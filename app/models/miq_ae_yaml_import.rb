class MiqAeYamlImport
  include Vmdb::Logging
  include MiqAeYamlImportExportMixin

  attr_reader :import_stats

  def initialize(domain, options)
    @domain_name = domain
    @options     = options
    @restore     = @options.fetch('restore', false)
    tenant_id    = @options['tenant_id']
    @tenant      = @options['tenant'] || (tenant_id ? Tenant.find_by!(:id => tenant_id) : Tenant.root_tenant)
  end

  def import
    if @options.key?('import_dir') && !File.directory?(@options['import_dir'])
      raise MiqAeException::DirectoryNotFound, "Directory [#{@options['import_dir']}] not found"
    end

    start_import(@options['preview'], @domain_name)
  end

  def start_import(preview, domain_name)
    if @options['import_as'] && !new_domain_name_valid?
      raise MiqAeException::InvalidDomain, "Error - New domain exists already, #{@options['import_as']}"
    end

    @preview = preview
    _log.info("Import options: <#{@options}> preview: <#{@preview}>")
    _log.info("Importing domain:    <#{domain_name}>")
    reset_stats
    @single_domain = true
    result = domain_name == ALL_DOMAINS ? import_all_domains : import_domain(domain_folder(domain_name), domain_name)
    log_stats
    result
  end

  def log_stats
    _log.info("Import statistics: <#{@import_stats.inspect}>")
    if @preview
      $log.warn("Your database has NOT been updated. Set PREVIEW=false to apply the above changes.")
    else
      $log.info("Your database has been updated.")
    end
  end

  def reset_stats
    @import_stats = {:domain => Hash.new(0), :namespace => Hash.new(0),
                     :class  => Hash.new(0), :instance => Hash.new(0),
                     :method => Hash.new(0)}
  end

  def import_all_domains
    @single_domain = false
    domains = sorted_domain_files.collect do |file|
      directory = File.dirname(file)
      @domain_name = directory.split("/").last
      import_domain(directory, @domain_name)
    end
    if @restore && !@preview
      MiqAeDatastore.reset_default_namespace
      MiqAeDomain.reset_priorities
    end
    domains
  end

  def sorted_domain_files
    domains = {}
    domain_files(ALL_DOMAINS).sort.each do |file|
      directory = File.dirname(file)
      domain_name = directory.split("/").last
      domain_yaml = read_domain_yaml(directory, domain_name)
      domains[file] = domain_yaml.fetch_path('object', 'attributes', 'priority')
    end
    domains.keys.sort_by { |k| domains[k] }
  end

  def preimport_check(domain_name, source_dom_source, dest_dom_source)
    dest_domain_name = @options['import_as'] == '*' || @options['import_as'].nil? ? @domain_name : @options['import_as']
    if source_dom_source == MiqAeDomain::SYSTEM_SOURCE
      if @options['git_repository_id']
        raise MiqAeException::InvalidDomain, _('Git based system domain import is not supported.')
      elsif !base_domain?(domain_name)
        raise MiqAeException::InvalidDomain, _('System domain import is not supported.')
      elsif domain_name != dest_domain_name
        raise MiqAeException::InvalidDomain, _('Domain name change for a system domain import is not supported.')
      end
    elsif domain_locked?(dest_domain_name)
      if @options['git_repository_id'] && dest_dom_source == MiqAeDomain::SYSTEM_SOURCE
        raise MiqAeException::DomainNotAccessible, _('Git based system domain import is not supported.')
      elsif @options['zip_file'] || (@options['git_repository_id'] && system_domain?(dest_domain_name))
        raise MiqAeException::DomainNotAccessible, _('Cannot import into a locked domain.')
      end
    end
  end

  def import_domain(domain_folder, domain_name)
    domain_yaml = domain_properties(domain_folder, domain_name)
    domain_name = domain_yaml.fetch_path('object', 'attributes', 'name')
    domain_source = domain_yaml.fetch_path('object', 'attributes', 'source')
    domain_obj = MiqAeDomain.lookup_by_fqname(domain_name, false)
    preimport_check(domain_folder, domain_source, domain_obj&.source) unless User.current_user.nil?
    track_stats('domain', domain_obj)
    MiqAeDomain.transaction do
      if domain_obj && !@preview && @options['overwrite']
        domain_obj.ae_namespaces.destroy_all
      end
      domain_obj ||= add_domain(domain_yaml, @tenant) unless @preview
      if @options['namespace']
        import_namespace(File.join(domain_folder, @options['namespace']), domain_obj, domain_name)
      else
        import_all_namespaces(domain_folder, domain_obj, domain_name)
      end
      update(domain_obj) if domain_obj
      domain_obj
    end
  end

  def domain_properties(domain_folder, name)
    domain_yaml = read_domain_yaml(domain_folder, name)
    if @options['import_as'] && @single_domain
      name = @options['import_as']
      domain_yaml.store_path('object', 'attributes', 'name', name)
    end
    miq = name.downcase == MiqAeDatastore::MANAGEIQ_DOMAIN.downcase
    miq ? reset_manageiq_attributes(domain_yaml) : reset_domain_attributes(domain_yaml)
    domain_yaml
  end

  def reset_manageiq_attributes(domain_yaml)
    domain_yaml.store_path('object', 'attributes', 'name', MiqAeDatastore::MANAGEIQ_DOMAIN)
    domain_yaml.store_path('object', 'attributes', 'priority', MiqAeDatastore::MANAGEIQ_PRIORITY)
    domain_yaml.store_path('object', 'attributes', 'source', MiqAeDomain::SYSTEM_SOURCE)
    domain_yaml.store_path('object', 'attributes', 'enabled', true)
    domain_yaml.delete_path('object', 'attributes', 'system')
  end

  def reset_domain_attributes(domain_yaml)
    domain_yaml.delete_path('object', 'attributes', 'enabled') unless @restore
    domain_yaml.delete_path('object', 'attributes', 'tenant_id') unless @restore
    domain_yaml.delete_path('object', 'attributes', 'priority')
    source_from_system(domain_yaml) if domain_yaml.has_key_path?('object', 'attributes', 'system')
    enable_system_domains(domain_yaml) if domain_yaml.has_key_path?('object', 'attributes', 'source')
  end

  def source_from_system(domain_yaml)
    system = domain_yaml.delete_path('object', 'attributes', 'system')
    if system == true
      domain_yaml.store_path('object', 'attributes', 'source', MiqAeDomain::USER_LOCKED_SOURCE)
    else
      domain_yaml.store_path('object', 'attributes', 'source', MiqAeDomain::USER_SOURCE)
    end
  end

  def enable_system_domains(domain_yaml)
    source = domain_yaml.fetch_path('object', 'attributes', 'source')
    if source == MiqAeDomain::SYSTEM_SOURCE
      domain_yaml.store_path('object', 'attributes', 'enabled', true)
    end
  end

  def import_all_namespaces(namespace_folder, domain_obj, domain_name)
    namespace_files(namespace_folder).sort.each do |file|
      import_namespace(File.dirname(file), domain_obj, domain_name)
    end
  end

  def import_namespace(namespace_folder, domain_obj, domain_name)
    namespace_file = File.join(namespace_folder, NAMESPACE_YAML_FILENAME)
    process_namespace(domain_obj, namespace_folder, load_file(namespace_file), domain_name)
  end

  def process_namespace(domain_obj, namespace_folder, namespace_yaml, domain_name)
    fqname = if @domain_name == '.'
               "#{domain_name}/#{namespace_folder}"
             else
               "#{domain_name}#{namespace_folder.sub(domain_folder(@domain_name), '')}"
             end
    _log.info("Importing namespace: <#{fqname}>")
    namespace_obj = MiqAeNamespace.lookup_by_fqname(fqname, false)
    track_stats('namespace', namespace_obj)
    namespace_obj ||= add_namespace(fqname) unless @preview
    attrs = namespace_yaml.fetch_path('object', 'attributes').slice('display_name', 'description')
    namespace_obj.update(attrs) unless @preview
    if @options['class_name']
      import_class(File.join(namespace_folder, "#{@options['class_name']}#{CLASS_DIR_SUFFIX}"), namespace_obj)
    else
      import_all_classes(namespace_folder, namespace_obj)
      import_all_namespaces(namespace_folder, domain_obj, domain_name)
    end
  end

  def import_all_classes(namespace_folder, namespace_obj)
    class_files(namespace_folder).each do |file|
      import_class(File.dirname(file), namespace_obj)
    end
  end

  def import_class(class_folder, namespace_obj)
    class_obj = existing_class_object(namespace_obj, load_class_schema(class_folder))
    process_class_components(class_folder, namespace_obj) if class_obj.nil?
  end

  def process_class_components(class_folder, namespace_obj)
    class_obj = process_class_schema(namespace_obj, load_class_schema(class_folder))
    add_class_components(class_folder, class_obj)
  end

  def add_class_components(class_folder, class_obj)
    _log.info("Importing class:     <#{class_obj.name}>") unless @preview
    get_instance_files(class_folder).each do |file|
      process_instance(class_obj, load_file(file)) unless File.basename(file) == CLASS_YAML_FILENAME
    end
    get_method_files(class_folder).each do |file|
      process_method(class_obj, file, load_file(file))
    end
  end

  def process_class_schema(namespace_obj, class_yaml)
    class_obj = existing_class_object(namespace_obj, class_yaml)
    class_obj ||= add_class_schema(namespace_obj, class_yaml) unless @preview
    class_obj
  end

  def existing_class_object(ns_obj, class_yaml)
    class_attrs = class_yaml.fetch_path('object', 'attributes')
    class_obj = MiqAeClass.lookup_by_namespace_id_and_name(ns_obj.id, class_attrs['name']) unless ns_obj.nil?
    track_stats('class', class_obj)
    class_obj
  end

  def process_instance(class_obj, instance_yaml)
    inst_attrs   = instance_yaml.fetch_path('object', 'attributes')
    instance_obj = MiqAeInstance.find_by(:class_id => class_obj.id, :name => inst_attrs['name']) unless class_obj.nil?
    track_stats('instance', instance_obj)
    instance_obj ||= add_instance(class_obj, instance_yaml) unless @preview
    instance_obj
  end

  def process_method(class_obj, ruby_method_file_name, method_yaml)
    method_attributes = method_yaml.fetch_path('object', 'attributes')
    if method_attributes['location'] == 'inline'
      data = load_method_ruby(ruby_method_file_name)
      method_yaml.store_path('object', 'attributes', 'data', data) if data
    elsif method_attributes['location'] == 'playbook'
      convert_playbook_attributes(method_attributes['options'], ruby_method_file_name)
    end
    method_obj = MiqAeMethod.find_by(:name => method_attributes['name'], :class_id => class_obj.id) unless class_obj.nil?
    track_stats('method', method_obj)
    method_obj ||= add_method(class_obj, method_yaml) unless @preview
    method_obj
  end

  def convert_playbook_attributes(options, ruby_method_file_name)
    invalid_attributes = []
    %w[repository playbook credential vault_credential cloud_credential].each do |attr|
      next unless options["#{attr}_name".to_sym]

      convert_playbook_attribute(options, attr, invalid_attributes)
    end

    unless invalid_attributes.empty?
      error_msg = _("Error: Playbook method '%{method_name}' contains below listed error(s):") % { :method_name => ruby_method_file_name }
      invalid_attributes.each do |attr|
        error_msg += "<br> * #{playbook_attr_error_msg(attr, options)}"
      end
      raise MiqAeException::AttributeNotFound, error_msg
    end
    options.except!(:repository_name, :playbook_name, :credential_name, :vault_credential_name, :cloud_credential_name)
  end

  def convert_playbook_attribute(options, attr, invalid_attributes)
    ae_manager = ManageIQ::Providers::EmbeddedAnsible::AutomationManager
    klass = case attr
            when 'repository'
              AnsibleRepositoryController.model
            when 'playbook'
              ae_manager::Playbook
            when 'credential'
              ae_manager::Credential
            when 'vault_credential'
              ae_manager::VaultCredential
            when 'cloud_credential'
              ae_manager::CloudCredential
            end
    related_obj = klass.find_by(:name => options["#{attr}_name".to_sym])

    if related_obj
      options["#{attr}_id".to_sym] = related_obj.id.to_s
    else
      invalid_attributes << attr
    end
  end

  def playbook_attr_error_msg(attr, options)
    case attr
    when 'repository'
      _("Repository '%{repository_name}' not found in database. Please try and import this repo "\
        "into this appliance and retry the import. If the repository has been deleted this import will never succeed.") \
        % {:repository_name => options[:repository_name]}
    when 'playbook'
      _("Playbook '%{playbook_name}' not found in repository '%{repository_name}', you  can refresh "\
        "the repo or change the branch or tag and retry the import, if the playbook doesn't exist in the repo this "\
        "import will never succeed, you can try importing by skiping this playbook using --skip_playbook pb1, pb2.") \
        % {:playbook_name => options[:playbook_name], :repository_name => options[:repository_name]}
    when 'credential'
      _("Credential '%{credential_name}' doesn't exist in the appliance, please add this credential and retry the import.") \
        % {:credential_name => options[:credential_name]}
    when 'vault_credential'
      _("Vault Credential '%{vault_credential_name}' doesn't exist in the appliance please add this credential and retry the import.") \
        % {:vault_credential_name => options[:vault_credential_name]}
    when 'cloud_credential'
      _("Cloud Credential '%{cloud_credential_name}' doesn't exist in the appliance please add this credential and retry the import.") \
        % {:cloud_credential_name => options[:cloud_credential_name]}
    end
  end

  def track_stats(level, object)
    mode = object.nil? ? 'add' : 'update'
    @import_stats[level.to_sym][mode] += 1
  end

  def new_domain_name_valid?
    return true if @options['overwrite']

    domain_obj = MiqAeDomain.lookup_by_fqname(@options['import_as'], false)
    if domain_obj
      _log.info("Cannot import - A domain exists with new domain name: #{@options['import_as']}.")
      return false
    end
    true
  end

  def update(domain_obj)
    return if domain_obj.name.downcase == MiqAeDatastore::MANAGEIQ_DOMAIN.downcase

    attrs = @options.slice('enabled', 'source')
    domain_obj.update(attrs) unless attrs.empty?
  end

  private

  def domain_locked?(domain_name)
    MiqAeDomain.find_by(:name => domain_name)&.contents_locked? ? true : false
  end

  def system_domain?(domain_name)
    MiqAeDomain.find_by(:name => domain_name)&.source == MiqAeDomain::SYSTEM_SOURCE
  end

  def base_domain?(domain_name)
    MiqAeDatastore.default_domain_names.include?(domain_name)
  end
end
