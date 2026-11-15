# frozen_string_literal: true

require "rails_helper"

# The entitlements render in the v1 subscription shape: no datetime to render to the microsecond.
RSpec.describe Api::V2::Contracts::EntitlementsController, v2_timestamps: false do
  let_it_be(:organization, refind: true) { create_default(:organization) }
  let_it_be(:customer) { create(:customer, organization:) }
  let_it_be(:catalog_plan) { create(:catalog_plan, organization:) }
  let_it_be(:feature) { create(:feature, organization:, code: "seats", name: "Seats", description: "Users") }
  let_it_be(:privilege) { create(:privilege, organization:, feature:, code: "max", name: "Max", value_type: "integer") }
  let_it_be(:plan_entitlement) { create(:entitlement, :catalog_plan, organization:, catalog_plan:, feature:) }

  let(:contract) { create(:contract, organization:, customer:, catalog_plan:, external_id: "contract-1") }

  before_all { create(:entitlement_value, organization:, entitlement: plan_entitlement, privilege:, value: 50) }

  def seats(value:, override_value:, overrides:)
    {
      code: "seats",
      name: "Seats",
      description: "Users",
      privileges: [
        {code: "max", name: "Max", value_type: "integer", value:, plan_value: 50, override_value:, config: {}}
      ],
      overrides:
    }
  end

  describe "PATCH /api/v2/contracts/:external_id/entitlements" do
    subject(:request) do
      patch_with_token(organization, "/api/v2/contracts/#{external_id}/entitlements#{query}", request_params)
    end

    let(:external_id) { contract.external_id }
    let(:query) { "" }
    let(:request_params) { {entitlements: {seats: {max: 60}}} }

    shared_examples "a refused write" do |status, body|
      it "refuses the write" do
        request

        expect(response).to have_http_status(status)
        expect(json).to eq(body)
        expect(Entitlement::Entitlement.where(contract_id: contract.id)).to be_empty
      end
    end

    include_examples "requires API permission", "contract", "write"

    it "merges the value as an override and returns every entitlement" do
      request

      expect(response).to have_http_status(:success)
      expect(json).to eq(entitlements: [seats(value: 60, override_value: 60, overrides: {max: 60})])
      expect(plan_entitlement.values.reload.map(&:value)).to eq(["50"])
    end

    context "with an override set to the catalog plan value" do
      let(:request_params) { {entitlements: {seats: {max: 50}}} }
      let(:contract_entitlement) { create(:entitlement, :contract, organization:, contract:, feature:) }

      before { create(:entitlement_value, organization:, entitlement: contract_entitlement, privilege:, value: 80) }

      it "drops the override" do
        request

        expect(response).to have_http_status(:success)
        expect(json).to eq(entitlements: [seats(value: 50, override_value: nil, overrides: {})])
      end
    end

    context "with a feature that only the contract grants" do
      let(:request_params) { {entitlements: {sso: {domains: "lago.com"}}} }

      before do
        sso = create(:feature, organization:, code: "sso", name: "SSO", description: nil)
        create(:privilege, organization:, feature: sso, code: "domains", name: nil, value_type: "string")
      end

      it "adds it next to the catalog plan entitlements" do
        request

        expect(response).to have_http_status(:success)
        expect(json).to eq(
          entitlements: [
            seats(value: 50, override_value: nil, overrides: {}),
            {
              code: "sso",
              name: "SSO",
              description: nil,
              privileges: [
                {code: "domains", name: nil, value_type: "string", value: "lago.com", plan_value: nil, override_value: "lago.com", config: {}}
              ],
              overrides: {domains: "lago.com"}
            }
          ]
        )
      end
    end

    context "with an empty map" do
      let(:request_params) { {entitlements: {}} }

      it "changes nothing" do
        request

        expect(response).to have_http_status(:success)
        expect(json).to eq(entitlements: [seats(value: 50, override_value: nil, overrides: {})])
      end
    end

    context "with a pending and an active contract sharing the external id" do
      let(:pending_contract) { create(:contract, :pending, organization:, customer:, catalog_plan:, external_id: "contract-1") }

      before { pending_contract }

      it "writes on the pending one" do
        request

        expect(response).to have_http_status(:success)
        expect(pending_contract.entitlements.count).to eq(1)
        expect(contract.entitlements).to be_empty
      end

      context "with the active status" do
        let(:query) { "?status=active" }

        it "writes on the active one" do
          request

          expect(response).to have_http_status(:success)
          expect(contract.entitlements.count).to eq(1)
          expect(pending_contract.entitlements).to be_empty
        end
      end
    end

    %w[terminated canceled].each do |status|
      context "with a #{status} contract" do
        let(:contract) { create(:contract, status.to_sym, organization:, customer:, catalog_plan:, external_id: "contract-1") }
        let(:query) { "?status=#{status}" }

        include_examples "a refused write", :unprocessable_content,
          {code: "validation_errors", details: [{code: "contract_not_editable", field: "base", meta: {}}]}
      end
    end

    context "with the status of a terminated contract and a live sibling" do
      let(:query) { "?status=terminated" }
      let(:older) { create(:contract, :terminated, organization:, customer:, catalog_plan:, external_id: "contract-1", started_at: 2.months.ago) }
      let(:latest) { create(:contract, :terminated, organization:, customer:, catalog_plan:, external_id: "contract-1", started_at: 1.month.ago) }

      before do
        contract
        older
        latest
      end

      it "refuses the write on the latest terminated one" do
        request

        expect(response).to have_http_status(:unprocessable_content)
        expect(json).to eq(code: "validation_errors", details: [{code: "contract_not_editable", field: "base", meta: {}}])
        expect(Entitlement::Entitlement.where(contract_id: [contract.id, older.id, latest.id])).to be_empty
      end
    end

    context "with an unknown status" do
      let(:query) { "?status=foo" }

      include_examples "a refused write", :unprocessable_content,
        {
          code: "validation_errors",
          details: [
            {code: "value_is_invalid", field: "status", meta: {allowed_values: %w[pending active terminated canceled]}}
          ]
        }
    end

    context "when no contract has the status" do
      let(:query) { "?status=pending" }

      it "returns not found" do
        request

        expect(response).to be_v2_not_found_error("contract")
      end
    end

    context "with an external id containing a dot" do
      let(:contract) { create(:contract, organization:, customer:, catalog_plan:, external_id: "contract.1") }

      it "finds the contract" do
        request

        expect(response).to have_http_status(:success)
        expect(json).to eq(entitlements: [seats(value: 60, override_value: 60, overrides: {max: 60})])
      end
    end

    context "with an unknown external id" do
      let(:external_id) { "unknown" }

      it "returns not found" do
        request

        expect(response).to be_v2_not_found_error("contract")
      end
    end

    context "with a contract of another organization" do
      let(:other_organization) { create(:organization) }
      let(:contract) { create(:contract, organization: other_organization, customer: create(:customer, organization: other_organization)) }

      it "returns not found" do
        request

        expect(response).to be_v2_not_found_error("contract")
        expect(contract.entitlements).to be_empty
      end
    end

    context "without entitlements" do
      let(:request_params) { {} }

      include_examples "a refused write", :bad_request,
        {code: "missing_parameter", details: [{code: "missing", field: "entitlements", meta: {}}]}
    end

    context "with a privilege value that is not a scalar" do
      let(:request_params) { {entitlements: {seats: {max: [60]}}} }

      include_examples "a refused write", :bad_request,
        {code: "value_is_invalid", details: [{code: "value_is_invalid", field: "entitlements.seats.max", meta: {}}]}
    end

    context "with a feature that is not a map" do
      let(:request_params) { {entitlements: {seats: 60}} }

      include_examples "a refused write", :bad_request,
        {code: "value_is_invalid", details: [{code: "value_is_invalid", field: "entitlements.seats", meta: {}}]}
    end

    context "with an unknown feature" do
      let(:request_params) { {entitlements: {seats: {max: 60}, unknown: {max: 1}}} }

      include_examples "a refused write", :unprocessable_content,
        {code: "validation_errors", details: [{code: "resource_not_found", field: "entitlements.unknown", meta: {resource: "feature"}}]}
    end

    context "with an unknown privilege" do
      let(:request_params) { {entitlements: {seats: {max: 60, unknown: 1}}} }

      include_examples "a refused write", :unprocessable_content,
        {code: "validation_errors", details: [{code: "resource_not_found", field: "entitlements.seats.unknown", meta: {resource: "privilege"}}]}
    end

    context "with an invalid value" do
      let(:request_params) { {entitlements: {seats: {max: "many"}}} }

      include_examples "a refused write", :unprocessable_content,
        {code: "validation_errors", details: [{code: "value_is_invalid", field: "entitlements.seats.max", meta: {}}]}
    end

    context "with a select value outside the options" do
      let(:request_params) { {entitlements: {seats: {invitation: "fax"}}} }

      before { create(:privilege, organization:, feature:, code: "invitation", name: nil, value_type: "select", config: {select_options: %w[email phone]}) }

      include_examples "a refused write", :unprocessable_content,
        {
          code: "validation_errors",
          details: [{code: "value_not_in_select_options", field: "entitlements.seats.invitation", meta: {allowed_values: %w[email phone]}}]
        }
    end

    %w[page per_page limit after].each do |name|
      context "with the #{name} pagination parameter" do
        let(:query) { "?#{name}=1" }

        include_examples "a refused write", :bad_request,
          {code: "invalid_pagination_parameter", details: [{code: "not_paginated", field: name, meta: {}}]}
      end
    end

    context "without the product catalog", product_catalog: false do
      include_examples "a refused write", :forbidden, {code: "feature_unavailable", details: []}
    end
  end
end
