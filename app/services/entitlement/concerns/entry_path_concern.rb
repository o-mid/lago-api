# frozen_string_literal: true

module Entitlement
  module Concerns
    # Puts the failure of a write of an entitlements map on the path of the failing entry, which native v2 renders as
    # the field: entitlements.<feature>[.<privilege>]. The service sets @current_feature_code and @current_privilege_code
    # as it walks the map, and declares `failed_field` on its result.
    module EntryPathConcern
      extend ActiveSupport::Concern

      private

      # NOTE: The failures keep the keys that v1 and GraphQL clients read. The path of the failing entry
      #       lets the v2 controller point an unknown feature or privilege at entitlements.<feature>[.<privilege>].
      def record_failing_entry
        result.failed_field = entitlement_entry_field(@current_feature_code, @current_privilege_code) if @current_feature_code
      end

      # The path of an entry in the entitlements map of a request, which native v2 renders as the field.
      def entitlement_entry_field(feature_code, privilege_code = nil)
        privilege_code.nil? ? :"entitlements.#{feature_code}" : :"entitlements.#{feature_code}.#{privilege_code}"
      end

      # The failure with the codes and meta of v1_field on the path of the failing entry, which native v2
      # renders. Its messages keep the keys that v1 and GraphQL clients read.
      def at_entry_path(failure, v1_field)
        entry_path = entitlement_entry_field(@current_feature_code, @current_privilege_code)
        v2_field = ->(field) { (field.to_sym == v1_field) ? entry_path : field }

        BaseService::ValidationFailure.new(
          result,
          messages: failure.messages,
          codes: failure.codes.transform_keys(&v2_field),
          meta: failure.meta.transform_keys(&v2_field)
        )
      end

      # v1 and GraphQL clients read privilege.<attribute>.
      def entitlement_value_failure(entitlement_value)
        failure = BaseService::ValidationFailure.from_errors(result, entitlement_value.errors).remap(result) { :"privilege.#{it}" }

        at_entry_path(failure, :"privilege.value")
      end
    end
  end
end
