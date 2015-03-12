#
# Copyright (c) 2013-2015 SKYARCH NETWORKS INC.
#
# This software is released under the MIT License.
#
# http://opensource.org/licenses/mit-license.php
#

class ResourcesController < ApplicationController
  # TODO: auth

  # GET /resources
  # @param [Integer] infra_id
  def index
    infra_id = params.require(:infra_id)
    infra = Infrastructure.find(infra_id)
    resources = infra.resources_or_create

    # TODO: format
    resp = {
      ec2_instances: resources.ec2,
      rds_instances: resources.rds,
      s3_buckets:    resources.s3,
    }

    render json: resp and return
  end

  # POST /resources
  # @param [Integer] infra_id
  # @param [String] physical_id
  # @param [String] screen_name Optional
  def create
    infra_id    = params.require(:infra_id)
    physical_id = params.require(:physical_id)
    screen_name = params[:screen_name] || physical_id
    type_name   = 'AWS::EC2::Instance' # TODO: 決め打ち

    #TODO: check aws
    #TODO: check infra status

    begin
      Resource.create!(
        infrastructure_id: infra_id,
        physical_id:       physical_id,
        screen_name:       screen_name,
        type_name:         type_name,
      )
    rescue => ex
      render text: ex.message, status: 500 and return
    end

    render text: I18n.t('resources.msg.created') and return
  end
end
