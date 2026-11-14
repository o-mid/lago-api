# frozen_string_literal: true

module Api
  module V2
    module Contracts
      # The entitlements of a contract, in the v1 subscription body with the v2 errors.
      class EntitlementsController < Api::V2::BaseController
        include Api::EntitlementsBody

        serializable_with ::V1::Entitlement::ContractEntitlementSerializer, root: :entitlement, expand_on: []

        before_action :reject_pagination!
        before_action :find_contract
        before_action :reject_invalid_entitlements_body!, only: :update

        # The list is returned whole.
        def index
          render_entitlements(::Entitlement::SubscriptionEntitlement.for_contract(contract))
        end

        def update
          result = ::Entitlement::ContractEntitlementUpdateService.call(contract:, entitlements_params:)

          if result.success?
            render_entitlements(result.entitlements)
          else
            render_entitlements_error(result)
          end
        end

        private

        attr_reader :contract

        # Without a status, the live contract (the pending one first); with one, the latest of that status.
        def find_contract
          status = params[:status]
          contracts = current_organization.contracts
          external_id = params[:external_id]

          if status.blank?
            @contract = contracts.live_by_external_id(external_id)
          elsif Contract::STATUSES.value?(status)
            @contract = contracts.latest_by_external_id(external_id, status:)
          else
            return validation_errors(errors: {status: ["value_is_invalid"]}, meta: {status: {allowed_values: Contract::STATUSES.values}})
          end

          not_found_error(resource: "contract") unless @contract
        end

        def resource_name
          "contract"
        end
      end
    end
  end
end
