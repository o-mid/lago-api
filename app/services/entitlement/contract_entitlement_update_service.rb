# frozen_string_literal: true

module Entitlement
  # Merges an entitlements map into the overrides of a contract. A value equal to the catalog plan
  # value drops the override, as on v1 subscriptions.
  class ContractEntitlementUpdateService < BaseService
    include ::Entitlement::Concerns::OwnerLockConcern
    include ::Entitlement::Concerns::OverrideOwnerConcern
    include ::Entitlement::Concerns::EntryPathConcern

    Result = BaseResult[:entitlements, :failed_field]

    def initialize(contract:, entitlements_params:)
      @contract = contract
      @entitlements_params = entitlements_params.to_h.with_indifferent_access
      super
    end

    activity_loggable(
      action: "contract.updated",
      record: -> { contract }
    )

    def call
      return result.not_found_failure!(resource: "contract") unless contract

      ActiveRecord::Base.transaction do
        lock_contract!(contract)
        update_entitlements
      end

      result.entitlements = SubscriptionEntitlement.for_contract(contract)
      result
    rescue BaseService::ValidationFailure => e
      # The core service names the failing privilege in the v1 key <privilege>_privilege_value.
      @current_privilege_code = entitlements_params[@current_feature_code]&.keys&.find { e.messages.key?(:"#{it}_privilege_value") } if @current_feature_code
      record_failing_entry
      result.fail_with_error!(@current_privilege_code ? at_entry_path(e, :"#{@current_privilege_code}_privilege_value") : e)
    rescue BaseService::FailedResult => e
      record_failing_entry
      result.fail_with_error!(e)
    rescue ActiveRecord::RecordNotUnique => e
      unique_index_failure!(e, CONTRACT_UNIQUE_INDEXES)
    rescue ActiveRecord::RecordInvalid => e
      if e.record.is_a?(EntitlementValue)
        @current_privilege_code = e.record.privilege&.code
        record_failing_entry
        result.fail_with_error!(entitlement_value_failure(e.record))
      else
        result.record_validation_failure!(record: e.record)
      end
    rescue ActiveRecord::RecordNotFound => e
      record_failing_entry
      if e.message.include?("Entitlement::Feature")
        result.not_found_failure!(resource: "feature")
      elsif e.message.include?("Entitlement::Privilege")
        result.not_found_failure!(resource: "privilege")
      else
        result.not_found_failure!(resource: "record")
      end
    end

    private

    attr_reader :contract, :entitlements_params
    delegate :organization, to: :contract

    def update_entitlements
      return if entitlements_params.blank?

      features_by_code = organization.features
        .where(code: entitlements_params.keys)
        .includes(:privileges)
        .index_by(&:code)
      feature_ids = features_by_code.values.map(&:id)

      plan_entitlements_by_feature_id = owner_plan_entitlements(contract)
        .where(entitlement_feature_id: feature_ids)
        .includes(values: :privilege)
        .index_by(&:entitlement_feature_id)

      contract_entitlements_by_feature_id = contract.entitlements
        .where(entitlement_feature_id: feature_ids)
        .includes(values: :privilege)
        .index_by(&:entitlement_feature_id)

      entitlements_params.each do |feature_code, privilege_params|
        @current_feature_code = feature_code
        @current_privilege_code = nil
        feature = features_by_code[feature_code]

        raise ActiveRecord::RecordNotFound.new("Entitlement::Feature") unless feature

        check_privileges!(feature, privilege_params)

        SubscriptionEntitlementCoreUpdateService.call!(
          owner: contract,
          plan: contract.catalog_plan,
          feature:,
          privilege_params:,
          plan_entitlement: plan_entitlements_by_feature_id[feature.id],
          sub_entitlement: contract_entitlements_by_feature_id[feature.id],
          partial: true
        )
      end
    end

    # Names the unknown privilege of the entry, which the core service refuses without its code.
    def check_privileges!(feature, privilege_params)
      privilege_params.to_h.each_key do |privilege_code|
        next if feature.privileges.any? { it.code == privilege_code }

        @current_privilege_code = privilege_code
        raise ActiveRecord::RecordNotFound.new("Entitlement::Privilege")
      end
    end
  end
end
