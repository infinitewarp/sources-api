require "base64"
require "net/http"

module Api
  module V1
    class SourcesController < ApplicationController
      include Api::V1::Mixins::DestroyMixin
      include Api::V1::Mixins::IndexMixin
      include Api::V1::Mixins::ShowMixin
      include Api::V1::Mixins::UpdateMixin

      def create
        source_data = params_for_create
        source_data["uid"] = SecureRandom.uuid if source_data["uid"].nil?
        source = Source.create!(source_data)

        raise_event("#{model}.create", source.as_json)

        render :json => source, :status => :created, :location => instance_link(source)
      end

      def check_availability
        source = Source.find(params[:source_id])
        topic  = "platform.topological-inventory.operations-#{source.source_type.name}"

        if Sources::Api::Messaging.topics.include?(topic)
          logger.debug("publishing message to #{topic}...")

          Sources::Api::Messaging.client.publish_topic(
            :service => topic,
            :event   => "Source.availability_check",
            :payload => {
              :params => {
                :source_id       => source.id.to_s,
                :source_uid      => source.uid.to_s,
                :external_tenant => source.tenant.external_tenant
              }
            }
          )

          logger.debug("publishing message to #{topic}...Complete")
        else
          logger.error("not publishing message to non-existing topic: #{topic}")
        end

        check_application_availability(source)

        render :json => {}, :status => :accepted
      end

      private

      def check_application_availability(source)
        source.application_types.each do |app_type|
          app_env_prefix = app_type.name.split('/').last.upcase.tr('-', '_')
          url = ENV["#{app_env_prefix}_AVAILABILITY_CHECK_URL"]
          next if url.blank?

          begin
            headers = {
              "Content-Type"  => "application/json",
              "x-rh-identity" => Base64.strict_encode64({'identity' => { 'account_number' => source.tenant.external_tenant }}.to_json)
            }

            uri = URI.parse(url)
            net_http = Net::HTTP.new(uri.host, uri.port)
            net_http.open_timeout = net_http.read_timeout = 10

            request  = Net::HTTP::Post.new(uri.request_uri, headers)
            request.body = { "source_id" => source.id.to_s }.to_json

            response = net_http.request(request)
            raise response.message unless response.kind_of?(Net::HTTPSuccess)
          rescue => e
            logger.error("Failed to request application availability check of #{app_type.display_name} for Source id: #{source.id} - #{url} Error: #{e.message}")
          end
        end
      end
    end
  end
end
