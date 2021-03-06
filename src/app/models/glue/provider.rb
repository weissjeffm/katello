#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

module Glue::Provider

  def self.included(base)
    base.send :include, InstanceMethods
    base.class_eval do
      before_destroy :destroy_products_orchestration
    end
  end

  module InstanceMethods

    def import_manifest zip_file_path, options = {}
      options = { :async => false, :notify => false }.merge options
      options.assert_valid_keys(:force, :async, :notify)

      self.task_status

      ret = if options[:async]
              self.task_status = async(:organization => self.organization, :task_type => "import manifest").queue_import_manifest zip_file_path, options
              self.save!
            else
              queue_import_manifest zip_file_path, options
            end
      return ret
    end

    def delete_manifest options = {}
      options = { :async => false, :notify => false }.merge options
      options.assert_valid_keys(:async, :notify)

      self.task_status

      ret = if options[:async]
              self.task_status = async(:organization => self.organization, :task_type => "delete manifest").queue_delete_manifest options
              Rails.logger.debug("DEBUG ASYNC #{task_status.task_type}")
              self.save!
            else
              exec_delete_manifest
            end
      return ret
    end

    def sync
      Rails.logger.debug "Syncing provider #{name}"
      self.products.collect do |p|
        p.sync
      end.flatten
    end

    def synced?
      self.products.any? { |p| p.synced? }
    end

    #get last sync status of all repositories in this provider
    def latest_sync_statuses
      self.products.collect do |p|
        p.latest_sync_statuses()
      end.flatten
    end

    # Get the most relavant status for all the repos in this Provider
    def sync_status
      statuses = self.products.reject{|r| r.empty?}.map{|r| r.sync_status()}
      return ::PulpSyncStatus.new(:state => ::PulpSyncStatus::Status::NOT_SYNCED) if statuses.empty?

      #if any of repos sync still running -> provider sync running
      idx = statuses.index do |r| r.state.to_s == ::PulpSyncStatus::Status::RUNNING.to_s end
      return statuses[idx] if idx != nil

      #else if any of repos not synced -> provider not synced
      idx = statuses.index do |r| r.state.to_s == ::PulpSyncStatus::Status::NOT_SYNCED.to_s end
      return statuses[idx] if idx != nil

      #else if any of repos sync cancelled -> provider sync cancelled
      idx = statuses.index do |r| r.state.to_s == ::PulpSyncStatus::Status::CANCELED.to_s end
      return statuses[idx] if idx != nil

      #else if any of repos sync finished with error -> provider sync finished with error
      idx = statuses.index do |r| r.state.to_s == ::PulpSyncStatus::Status::ERROR.to_s end
      return statuses[idx] if idx != nil

      #else -> all finished
      return statuses[0]
    end

    def sync_state
      self.sync_status().state
    end

    def sync_start
      start_times = Array.new
      for p in self.products
        start = p.sync_start
        start_times << start unless start.nil?
      end
      start_times.sort!
      start_times.last
    end

    def sync_finish
      finish_times = Array.new
      for r in self.products
        finish = r.sync_finish
        finish_times << finish unless finish.nil?
      end
      finish_times.sort!
      finish_times.last
    end

    def sync_size
      size = self.products.inject(0) { |sum,v| sum + v.sync_status.progress.total_size }
    end

    def last_sync
      sync_times = Array.new
      for p in self.products
        sync = p.last_sync
        sync_times << sync unless sync.nil?
      end
      sync_times.sort!
      sync_times.last
    end

    def cancel_sync
      Rails.logger.debug "Cancelling synchronization of provider #{name}"
      self.products.each do |p|
        p.cancel_sync
      end
    end

    def add_custom_product(label, name, description, url, gpg = nil)
      # URL isn't used yet until we can do custom repo discovery in pulp
      begin
        Rails.logger.debug "Creating custom product #{name} for provider: #{self.name}"
        product = Product.new({
            :name => name,
            :label => label,
            :description => description,
            :multiplier => 1
        })
        self.products << product
        product.provider = self
        product.environments << self.organization.library
        product.gpg_key = gpg
        product.save!
        product
      rescue => e
        Rails.logger.error "Failed to create custom product #{name} for provider #{self.name}: #{e}, #{e.backtrace.join("\n")}"
        raise e
      end
    end

    def url_to_host_and_path(url = "")
      parsed = URI.parse(url)
      ["#{parsed.scheme}://#{parsed.host}#{ parsed.port ? ':' + parsed.port.to_s : '' }", parsed.path]
    end

    def del_products
      Rails.logger.debug "Deleting all products for provider: #{name}"
      # we first delete marketing products, because there are no repos for them
      # and they take care of deleting product <-> content association in CP
      # for themselves.
      self.products.where("type = 'MarketingProduct'").uniq.each(&:destroy)
      self.products.where("type <> 'MarketingProduct'").uniq.each(&:destroy)
      true
    rescue => e
      Rails.logger.error "Failed to delete all products for provider #{name}: #{e}, #{e.backtrace.join("\n")}"
      raise e
    end

    def owner_import zip_file_path, options
      Resources::Candlepin::Owner.import self.organization.label, zip_file_path, options
    end

    def del_owner_import
      # This method will delete a manifest that has been imported.  Since it is not possible
      # to delete the changes associated with a specific manifest, we only support deleting
      # the import, if there has only been 1 manifest import completed.  It should be noted
      # that this will destroy all subscriptions associated with the import.
      imports = self.owner_imports
      if imports.length == 1
        Rails.logger.debug "Deleting import for provider: #{name}"
        Resources::Candlepin::Owner.destroy_imports self.organization.label
      else
        Rails.logger.debug "Unable to delete import for provider: #{name}. Reason: a successful import was previously completed."
      end
    end

    def owner_imports
      Resources::Candlepin::Owner.imports self.organization.label
    end

    def queue_import_manifest zip_file_path, options
      begin
        Rails.logger.debug "Importing manifest for provider #{name}"
        pre_queue.create(:name     => "import manifest #{zip_file_path} for owner: #{self.organization.name}",
                         :priority => 3, :action => [self, :owner_import, zip_file_path, options],
                         :action_rollback => [self, :del_owner_import])
        pre_queue.create(:name     => "import of products in manifest #{zip_file_path}",
                         :priority => 5, :action => [self, :import_products_from_cp])
        self.save!

        if options[:notify]
          message = if AppConfig.katello?
                      _("Subscription manifest uploaded successfully for provider '%s'. " +
                            "Please enable the repositories you want to sync by selecting 'Enable Repositories' and " +
                            "selecting individual repositories to be enabled.")
                    else
                      _("Subscription manifest uploaded successfully for provider '%s'.")
                    end
          Notify.success message % self.name,
                         :request_type => 'providers__update_redhat_provider',
                         :organization => self.organization
        end
      rescue => error
        if error.respond_to?(:response)
          display_message = error.response # fix add parse displayMessage
        elsif error.message
          display_message = error.message
        else
          display_message = ""
        end
        display_message = ApplicationController.parse_display_message(display_message)

        if options[:notify]
          Notify.exception import_error_message(display_message), error,
                           :request_type => 'providers__update_redhat_provider',
                           :organization => self.organization
        end

        Rails.logger.error "error uploading subscriptions."
        Rails.logger.error error
        Rails.logger.error error.backtrace.join("\n")
        raise error
      end
    end

    def import_products_from_cp
      product_in_katello_ids = self.organization.providers.redhat.first.products.pluck("cp_id")
      products_in_candlepin_ids = []
      Util::CdnVarSubstitutor.with_cache do
        marketing_to_enginnering_product_ids_mapping.each do |marketing_product_id, engineering_product_ids|
          engineering_product_ids = engineering_product_ids.uniq
          products_in_candlepin_ids << marketing_product_id
          products_in_candlepin_ids.concat(engineering_product_ids)
          added_eng_products = (engineering_product_ids - product_in_katello_ids).map do |id|
            Resources::Candlepin::Product.get(id)[0]
          end
          adjusted_eng_products = []
          added_eng_products.each do |product_attrs|
            begin
              Glue::Candlepin::Product.import_from_cp(product_attrs) do |p|
                p.provider = self
                p.environments << self.organization.library
              end
              adjusted_eng_products << product_attrs
            rescue Errors::SecurityViolation => e
              # Do not add non-accessible products
              Rails.logger.info e
            end
          end

          product_in_katello_ids.concat(adjusted_eng_products.map{|p| p["id"]})

          unless product_in_katello_ids.include?(marketing_product_id)
            engineering_product_in_katello_ids = self.organization.library.products.where(:cp_id => engineering_product_ids).map(&:id)
            Glue::Candlepin::Product.import_marketing_from_cp(Resources::Candlepin::Product.get(marketing_product_id)[0], engineering_product_in_katello_ids) do |p|
              p.provider = self
              p.environments << self.organization.library
            end
            product_in_katello_ids << marketing_product_id
          end
        end
      end

      product_to_remove_ids = (product_in_katello_ids - products_in_candlepin_ids).uniq
      product_to_remove_ids.each { |cp_id| Product.find_by_cp_id(cp_id).destroy }

      self.index_subscriptions
      true
    end

    def destroy_products_orchestration
      pre_queue.create(:name => "delete products for provider: #{self.name}", :priority => 1, :action => [self, :del_products])
    end

    def import_error_message display_message
      error_texts = [
          _("Subscription manifest upload for provider '%s' failed.") % self.name,
          (_("Reason: %s") % display_message unless display_message.blank?)
      ].compact
      error_texts.join('<br />')
    end

    def exec_delete_manifest
      Resources::Candlepin::Owner.destroy_imports self.organization.label, true
      index_subscriptions
    end

    def index_subscriptions
      # Raw candlepin pools
      cp_pools = Resources::Candlepin::Owner.pools(self.organization.label)
      if cp_pools
        # Pool objects
        pools = cp_pools.collect{|cp_pool| ::Pool.find_pool(cp_pool['id'], cp_pool)}

        # Limit subscriptions to just those from Red Hat provider
        subscriptions = pools.collect do |pool|
          product = Product.where(:cp_id => pool.product_id, :provider_id => self.organization.redhat_provider.id).first
          next if product.nil?
          pool.provider_id = product.provider_id   # Set so it is saved into elastic search
          pool
        end.compact
        subscriptions = [] if subscriptions.nil?
      else
        subscriptions = []
      end

      # Index pools
      # Note: Only the Red Hat provider subscriptions are being indexed.
      ::Pool.index_pools(subscriptions, {:org=>self.organization.label, :provider_id=>self.organization.redhat_provider.id})

      subscriptions
    end

    def rollback_delete_manifest
      # Nothing to be done until implemented in katello where possible pulp recovery actions should be done(?)
    end

    def queue_delete_manifest options
      begin
        Rails.logger.debug "Deleting manifest for provider #{name}"
        pre_queue.create(:name     => "delete manifest for owner: #{self.organization.name}",
                         :priority => 3, :action => [self, :exec_delete_manifest],
                         :action_rollback => [self, :rollback_delete_manifest])
        self.save!

        if options[:notify]
          message = _("Subscription manifest deleted successfully for provider '%s'.")
          Notify.success message % self.name,
                         :request_type => 'providers__update_redhat_provider',
                         :organization => self.organization
        end
      rescue Exception => error
        if error.respond_to?(:response)
          display_message = error.response # fix add parse displayMessage
        elsif error.message
          display_message = error.message
        else
          display_message = ""
        end
        display_message = ApplicationController.parse_display_message(display_message)

        if options[:notify]
          Notify.exception import_error_message(display_message), error,
                           :request_type => 'providers__update_redhat_provider',
                           :organization => self.organization
        end

        Rails.logger.error "error uploading subscriptions."
        Rails.logger.error error
        Rails.logger.error error.backtrace.join("\n")
        raise error
      end
    end

    def delete_error_message display_message
      error_texts = [
          _("Subscription manifest delete for provider '%s' failed.") % self.name,
          (_("Reason: %s") % display_message unless display_message.blank?)
      ].compact
      error_texts.join('<br />')
    end

    protected

    # There are two types of products in Candlepin: marketing and engineering.
    # When promoting, we care only about the engineering products. These are
    # the products that content/repos are assigned to. The marketing product is
    # that one that subscriptions are assigned to. Between marketing and
    # enginering products is M:N relation (see MarketingEngineeringProduct
    # model)
    def marketing_to_enginnering_product_ids_mapping
      mapping = {}
      pools = Resources::Candlepin::Owner.pools self.organization.label
      pools.each do |pool|
        mapping[pool[:productId]] ||= []
        if pool[:providedProducts]
          eng_product_ids = pool[:providedProducts].map { |provided| provided[:productId] }
          mapping[pool[:productId]].concat(eng_product_ids)
        end
      end
      mapping
    end

    def get_all_product_ids
      Resources::Candlepin::Product.all.map{ |p| p['id'] }
    end

    def get_assigned_content_ids
      ids = Resources::Candlepin::Product.all.collect{ |p| p['productContent'] }.flatten(1).collect{ |content| content['content']['id'] }
      ids
    end

    def get_all_content_ids
      ids = Resources::Candlepin::Content.all.map{ |c| c['id'] }
      ids
    end
  end


end
