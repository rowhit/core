# Copyright 2013, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'uri'
require 'digest/md5'
require 'active_support/core_ext/string'

# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.
class ApplicationController < ActionController::Base

  before_filter :crowbar_auth

  # Basis for the reflection/help system.

  # First, a place to stash the help contents.
  # Using a class_inheritable_accessor ensures that
  # these contents are inherited by children, but can be
  # overridden or appended to by child classes without messing up
  # the contents we are building here.
  class_attribute :help_contents
  self.help_contents = []

  # Class method for adding method-specific help/API information
  # for each method we are going to expose to the CLI.
  # Since it is a class method, it will not be bothered by the Rails
  # trying to expose it to everything else, and we can call it to build
  # up our help contents at class creation time instead of snapshot creation
  # time, so there is minimal overhead.
  # Since we are just storing an arrray of singleton hashes, adding more
  # user-oriented stuff (descriptions, exmaples, etc.) should not be a problem.
  def self.add_help(method,args=[],http_method=[:get])
    # if we were passed multiple http_methods, build an entry for each.
    # This assumes that they all take the same parameters, if they do not
    # you should call add_help for each different set of parameters that the
    # method/http_method combo can take.
    http_method.each { |m|
      self.help_contents = self.help_contents.push({
        method => {
                                             "args" => args,
                                             "http_method" => m
        }
      })
    }
  end

  #helper :all # include all helpers, all the time

  protect_from_forgery # See ActionController::RequestForgeryProtection for details

  def self.set_layout(template = "application")
    layout proc { |controller|
      if controller.is_ajax?
        return nil
      end
      template
    }
  end

  # needed by Devise auth
  def is_ajax?
    request.xhr?
  end

  # creates the content type for a consistent API
  def cb_content_type(type, form="list")
    "application/vnd.crowbar.#{type2name(type)}.#{form}+json; version=2.0"
  end

  def api_wrong_version
    {
      :json=> {
        :message => I18n.t('api.wrong_version',:version=>params[:version]),
        :status => 400
      },
      :content_type=>cb_content_type("version", "error"),
      :status => 400
    }
  end

  def api_not_found(k,t)
    { :json => {
        :message => I18n.t('api.not_found', :id=>k, :type=>type2name(t)),
        :status => 404
      },
      :content_type=>cb_content_type(t, "error"),
      :status => :not_found
    }
  end

  def api_not_supported(verb, object)
    return {:json => {
        :message => I18n.t('api.not_supported', :verb=>verb.upcase, :obj=>object),
        :status => 405
      },
      :status => 405,
      :content_type=>cb_content_type(object, "error")
    }
  end

  def ui_not_supported(verb, object)
    return { :text=>I18n.t('ui.not_supported', :verb=>verb.upcase, :obj=>object),
      :status => 405,
      :content_type=>cb_content_type(object, "error")
    }
  end

  def version_ok
    params[:version].eql?('v2')
  end

  # formats API json output
  # using this makes it easier to update the API format for all models
  def api_index(type, list)
    return api_wrong_version unless version_ok
    return {:json=>list, :content_type=>cb_content_type(type, "list") }
  end

  # formats API json for output
  # using this makes it easier to update the API format for all models
  def api_show(o)
    return api_wrong_version unless version_ok
    return {:json=>o, :content_type=>cb_content_type(o, "obj") }
  end

  # formats API for delete
  # using this makes it easier to update the API format for all models
  def api_delete(o)
    return {:json => {
        :message => I18n.t('api.deleted', :id=>o.id, :obj=>type2name(o))
      },
      :content_type=>cb_content_type(o, "empty")
    }
  end

  # formats API json output 
  # used for json output that is not mapped to a Crowbar model
  def api_array(json)
    return api_wrong_version(params) unless version_ok(params)
    return {:json=>json, :content_type=>cb_content_type("json", "array") }
  end

  add_help(:help)
  def help
    render :json => { self.controller_name => self.help_contents.collect { |m|
        res = {}
        m.each { |k,v|
          # sigh, we cannot resolve url_for at class definition time.
          # I suppose we have to do it at runtime.
          url=URI::unescape(url_for({ :action => k,
                        :controller => self.controller_name,

          }.merge(v["args"].inject({}) {|acc,x|
            acc.merge({x.to_s => "(#{x.to_s})"})
          }
          )
          ))
          res.merge!({ k.to_s => v.merge({"url" => url})})
        }
        res
      }
    }
  end
  set_layout

  unless Rails.application.config.consider_all_requests_local
    rescue_from Exception, :with => :render_error
  end

  private

  def type2name(type)
    case
    when type.kind_of?(ActiveRecord::Base) then type.class.name.underscore
    when type.respond_to?(:descends_from_active_record?) &&
        type.descends_from_active_record? then type.name.underscore
    when type.kind_of?(String) then type.underscore
    when type.kind_of?(Symbol) then type.to_s.underscore
    else raise "type2name cannot handle #{type.inspect}"
    end
  end

  def render_error(exception)
    @error = exception
    case
    when @error.is_a?(ActiveRecord::RecordNotFound)
      respond_to do |format|
        format.html { render :status => 404 }
        format.json { render api_not_found(@error.crowbar_key, @error.crowbar_model) }
      end
    when @error.is_a?(ActiveRecord::RecordInvalid)
      respond_to do |format|
        format.html { render :status => 409 }
        format.json { render :json => {
            :message => @error.message,
            :backtrace => @error.backtrace,
            :status => 409
          },
          :status => 409,
          :content_type=>cb_content_type("record", "error")
        }
      end
    else
      Rails.logger.error(exception)
      respond_to do |format|
        format.html { render :template => "/errors/500.html.haml", :status => 500 }
        format.json { render :json => {
            :message => @error.message,
            :backtrace => @error.backtrace,
            :status => 500
          },
          :status => 500,
          :content_type=>cb_content_type("framework", "error")
        }
      end
    end
  end

  def digest_auth!
    authenticate_or_request_with_http_digest(User::DIGEST_REALM) do |username|
      u = User.find_by_username(username)
      session[:digest_user] = u.username
      u.encrypted_password
    end
    warden.custom_failure! if performed?
  end

  def do_auth!
    respond_to do |format|
      format.html { authenticate_user!  }
      format.json { digest_auth!  }
    end
  end

  #return true if we digest signed in
  def crowbar_auth
    case
    when current_user then authenticate_user!
    when request.headers["HTTP_AUTHORIZATION"] && request.headers["HTTP_AUTHORIZATION"].starts_with?('Digest username=') then digest_auth!
    when (request.local? ||
          (/^::ffff:127\.0\.0\.1$/ =~ request.remote_ip)) &&
        File.exists?("/tmp/.crowbar_in_bootstrap") &&
        (File.stat("/tmp/.crowbar_in_bootstrap").uid == 0)
      current_user = User.find_by_id_or_username("crowbar")
      true
    else
      do_auth!
    end
  end
end
