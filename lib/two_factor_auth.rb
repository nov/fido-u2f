require "two_factor_auth/engine"

require 'base64'
require 'json'
require 'openssl'
require 'active_model'
require 'active_model/validator'

module TwoFactorAuth
  U2F_VERSION = 'U2F_V2'

  class TwoFactorAuthError < RuntimeError ; end
    class CantGenerateRandomNumbers < TwoFactorAuthError ; end
    class InvalidPublicKey < TwoFactorAuthError ; end
    class InvalidFacetDomain < TwoFactorAuthError ; end


  def self.facet_domain= facet_domain
    if facet_domain =~ /localhost(:\d+)?\/?$/
      raise InvalidFacetDomain, "Facet domain can't be localhost, edit /etc/hosts to make a custom hostname"
    end
    # if facet_domain =~ /\.dev(:\d+)?\/?$/
    #   raise InvalidFacetDomain, "Facet domain needs a real TLD, not .dev. Edit /etc/hosts to make a custom hostname"
    # end
    if facet_domain == "https://www.example.com"
      raise InvalidFacetDomain, "You need to cusomize the facet_domain in config/initializers/two_factor_auth.rb"
    end

    @facet_domain = facet_domain.sub(/\/$/, '')
  end

  def self.facet_domain
    @facet_domain
  end

  def self.trusted_facet_list_url= url
    @trusted_facet_list_url = url
  end

  def self.trusted_facet_list_url
    @trusted_facet_list_url or "#{facet_domain}/two_factor_auth/trusted_facets"
  end

  def self.facets= facets
    @facets = facets
  end

  def self.facets
    if @facets.nil? or @facets.empty?
      [facet_domain]
    else
      @facets
    end
  end

  def self.websafe_base64_encode str
    # PHP code removes trailing =s, don't know why
    Base64.urlsafe_encode64(str).sub(/=+$/,'')
  end

  def self.websafe_base64_decode encoded
    # pad back out to decode
    padded = encoded.ljust((encoded.length/4.0).ceil * 4, '=')
    Base64.urlsafe_decode64(padded)
  end

  def self.random_encoded_challenge
    random = OpenSSL::Random.pseudo_bytes(32)
    TwoFactorAuth::websafe_base64_encode(random)
  rescue OpenSSL::Random::RandomError
    raise CantGenerateRandomNumbers, "Not enough entropy to generate secure challenges"
  end

  def self.decode_pubkey raw
    bn = OpenSSL::BN.new(raw, 2)
    group = OpenSSL::PKey::EC::Group.new('prime256v1')
    point = OpenSSL::PKey::EC::Point.new(group, bn)
  rescue OpenSSL::PKey::EC::Point::Error => e
    raise InvalidPublicKey, "Invalid public key: #{e.message}"
  end

  def self.pubkey_valid? raw
    pk = decode_pubkey raw
    pk.on_curve?
  rescue InvalidPublicKey
    false
  end
end

module ActiveModel
  module Validations
    class AssociatedValidator < ActiveModel::EachValidator #:nodoc:
      def validate_each(record, attribute, value)
        if Array.wrap(value).reject {|r| r.valid?}.any?
          record.errors.add(attribute, value.errors.full_messages.join("; "), options.merge(:value => value))
        end
      end
    end

    module ClassMethods
      # Validates whether the associated object or objects are all valid.
      # Works with any kind of association.
      #
      #   class Book < ActiveRecord::Base
      #     has_many :pages
      #     belongs_to :library
      #
      #     validates_associated :pages, :library
      #   end
      #
      # WARNING: This validation must not be used on both ends of an association.
      # Doing so will lead to a circular dependency and cause infinite recursion.
      #
      # NOTE: This validation will not fail if the association hasn't been
      # assigned. If you want to ensure that the association is both present and
      # guaranteed to be valid, you also need to use +validates_presence_of+.
      #
      # Configuration options:
      #
      # * <tt>:message</tt> - A custom error message (default is: "is invalid").
      # * <tt>:on</tt> - Specifies when this validation is active. Runs in all
      #   validation contexts by default (+nil+), other options are <tt>:create</tt>
      #   and <tt>:update</tt>.
      # * <tt>:if</tt> - Specifies a method, proc or string to call to determine
      #   if the validation should occur (e.g. <tt>if: :allow_validation</tt>,
      #   or <tt>if: Proc.new { |user| user.signup_step > 2 }</tt>). The method,
      #   proc or string should return or evaluate to a +true+ or +false+ value.
      # * <tt>:unless</tt> - Specifies a method, proc or string to call to
      #   determine if the validation should not occur (e.g. <tt>unless: :skip_validation</tt>,
      #   or <tt>unless: Proc.new { |user| user.signup_step <= 2 }</tt>). The
      #   method, proc or string should return or evaluate to a +true+ or +false+
      #   value.
      def validates_associated(*attr_names)
        validates_with AssociatedValidator, _merge_attributes(attr_names)
      end
    end
  end
end

module ActionDispatch::Routing
  class Mapper
    def two_factor_auth_for resource
      begin
        klass = resource.to_s.classify.constantize
      rescue NameError
        warn "You included two_factor_auth_for #{resource.inspect} in your routes but there is no model defined in your system"
      end
      namespace :two_factor_auth do
        resources(:registrations,   only: [:new, :create])
        resource(:authentication,   only: [:new, :create])
        resources(:trusted_facets,  only: [:index])
      end
    end
  end
end
