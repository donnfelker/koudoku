module Koudoku::Subscription
  extend ActiveSupport::Concern

  included do

    # We don't store these one-time use tokens, but this is what Stripe provides
    # client-side after storing the credit card information.
    attr_accessor :credit_card_token

    belongs_to :plan, optional: true

    # update details.
    before_save :processing!
    def processing!

      # if their package level has changed ..
      if changing_plans?

        prepare_for_plan_change

        # and a customer exists in stripe ..
        if stripe_id.present?

          # fetch the customer.
          customer = Stripe::Customer.retrieve(self.stripe_id)

          # if a new plan has been selected
          if self.plan.present?

            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_downgrade if downgrading?
            prepare_for_upgrade if upgrading?

            if coupon.present?
              prepare_for_coupon_application
              customer.coupon = coupon.code # Must apply the coupon as a code, not the object

              begin
                customer.save
              rescue Stripe::CardError => card_error
                errors[:base] << card_error.message
                card_was_declined
                throw(:abort)
              rescue Stripe::InvalidRequestError, Stripe::StripeError => e
                errors[:base] << e.message
                error_saving_customer(e)
                throw(:abort)
              end

              finalize_coupon_application!
            end

            # update the package level with stripe.
            begin
              customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate)
            rescue Stripe::CardError => card_error
              errors[:base] << card_error.message
              card_was_declined
              throw(:abort)
            rescue Stripe::InvalidRequestError, Stripe::StripeError => e
              errors[:base] << e.message
              error_updating_subscription(e)
              throw(:abort)
            end

            finalize_downgrade! if downgrading?
            finalize_upgrade! if upgrading?

          # if no plan has been selected.
          else

            prepare_for_cancelation

            begin
              # delete the subscription.
              customer.cancel_subscription
            rescue Stripe::InvalidRequestError, Stripe::StripeError => e
              Rails.logger.error e.message
            end

            finalize_cancelation!

          end

        # when customer DOES NOT exist in stripe ..
        else
          # if a new plan has been selected
          if self.plan.present?

            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_new_subscription
            prepare_for_upgrade

            begin
              raise Koudoku::NilCardToken, "Possible javascript error" if credit_card_token.empty?
              customer_attributes = {
                description: subscription_owner_description,
                email: subscription_owner_email,
                source: credit_card_token # obtained with Stripe.js
              }

              # If the class we're being included in supports coupons ..
              if respond_to? :coupon
                if coupon.present?
                  customer_attributes[:coupon] = coupon.code
                end
              end

              # create a customer at that package level.
              customer = Stripe::Customer.create(customer_attributes)

              finalize_new_customer!(customer.id, plan.price)
              customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate)

            rescue Stripe::CardError => card_error
              errors[:base] << card_error.message
              card_was_declined
              throw(:abort)
            end

            # store the customer id.
            self.stripe_id = customer.id
            self.last_four = customer.sources.retrieve(customer.default_source).last4

            finalize_new_subscription!
            finalize_upgrade!

          else

            # This should never happen.

            self.plan_id = nil

            # Remove any plan pricing.
            self.current_price = nil

          end

        end

        finalize_plan_change!

      elsif changing_cancellation_period?

        customer = Stripe::Customer.retrieve(self.stripe_id)

        if cancel_at_period_end?

          prepare_for_cancellation_period_change
          # Cancel at period end is true
          subscription = customer.cancel_subscription(at_period_end: true)
          self.current_period_end = Time.at(subscription.current_period_end).to_datetime

          finalize_cancellation_period_change

        else

          prepare_for_subscription_reactivation

          # Update the subscription so that it renews.
          # https://stripe.com/docs/subscriptions/canceling-pausing#reactivating-canceled-subscriptions
          subscription = customer.subscriptions.data[0]
          subscription.items = [{
                                    id: subscription.items.data[0].id,
                                    plan: subscription.items.data[0].plan.id
                                }]

          subscription.save

          self.cancel_at_period_end = false
          self.current_period_end = nil

          finalize_subscription_reactivation

        end

      elsif self.credit_card_token.present?

        prepare_for_card_update

        # fetch the customer.
        customer = Stripe::Customer.retrieve(self.stripe_id)
        customer.source = self.credit_card_token
        customer.save

        # update the last four based on this new card.
        self.last_four = customer.sources.retrieve(customer.default_source).last4
        finalize_card_update!

      end
    end
  end


  def describe_difference(plan_to_describe)
    if plan.nil?
      if persisted?
        I18n.t('koudoku.plan_difference.upgrade')
      else
        if Koudoku.free_trial?
          I18n.t('koudoku.plan_difference.start_trial')
        else
          I18n.t('koudoku.plan_difference.upgrade')
        end
      end
    else
      if plan_to_describe.is_upgrade_from?(plan)
        I18n.t('koudoku.plan_difference.upgrade')
      else
        I18n.t('koudoku.plan_difference.downgrade')
      end
    end
  end

  def cancel(force = false)

    if Koudoku.cancel_at_period_end && !force
      # Leave the subscription intact, but set the subscription to cancel at the billing period end.
      # To use this, you will need webhooks set up in your app, otherwise your cancellation will never
      # process as the actual cancellation occurs when Stripe calls your webhook, informing you that
      # the subscription is canceled with the 'customer.subscription.deleted' webhook event.
      self.cancel_at_period_end = true
    else
      self.plan_id = nil
      self.cancel_at_period_end = false
      self.current_period_end = nil

      # Remove the current pricing.
      self.current_price = nil
    end

  end

  def reactivate
    self.cancel_at_period_end = false
  end

  # Pretty sure this wouldn't conflict with anything someone would put in their model
  def subscription_owner
    # Return whatever we belong to.
    # If this object doesn't respond to 'name', please update owner_description.
    send Koudoku.subscriptions_owned_by
  end

  def subscription_owner=(owner)
    # e.g. @subscription.user = @owner
    send Koudoku.owner_assignment_sym, owner
  end

  def subscription_owner_description
    # assuming owner responds to name.
    # we should check for whether it responds to this or not.
    "#{subscription_owner.try(:name) || subscription_owner.try(:id)}"
  end

  def subscription_owner_email
    "#{subscription_owner.try(:email)}"
  end

  def changing_plans?
    plan_id_changed?
  end

  def changing_cancellation_period?
    Koudoku.cancel_at_period_end && cancel_at_period_end_changed?
  end

  def downgrading?
    plan.present? and plan_id_was.present? and plan_id_was > self.plan_id
  end

  def upgrading?
    (plan_id_was.present? and plan_id_was < plan_id) or plan_id_was.nil?
  end

  # Template methods.
  def prepare_for_plan_change
  end

  def prepare_for_new_subscription
  end

  def prepare_for_upgrade
  end

  def prepare_for_downgrade
  end

  def prepare_for_cancelation
  end

  def prepare_for_card_update
  end

  def prepare_for_coupon_application
  end

  def prepare_for_cancellation_period_change
  end

  def prepare_for_subscription_reactivation
  end

  def finalize_subscription_reactivation
  end

  def finalize_cancellation_period_change
  end

  def finalize_coupon_application!
  end

  def finalize_plan_change!
  end

  def finalize_new_subscription!
  end

  def finalize_new_customer!(customer_id, amount)
  end

  def finalize_upgrade!
  end

  def finalize_downgrade!
  end

  def finalize_cancelation!
  end

  def finalize_card_update!
  end

  def card_was_declined
  end

  # stripe web-hook callbacks.
  def payment_succeeded(amount)
  end

  def charge_failed
  end

  def charge_disputed
  end

  def error_updating_subscription(e)
  end

  def error_saving_customer(e)
  end

end
