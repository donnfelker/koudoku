Koudoku.setup do |config|
  config.subscriptions_owned_by = :<%= subscription_owner_model %>
  config.stripe_publishable_key = ENV['STRIPE_PUBLISHABLE_KEY']
  config.stripe_secret_key = ENV['STRIPE_SECRET_KEY']
  
  Stripe.api_version = '2015-04-07' #Making sure the API version used is compatible.
  # config.prorate = false # Default is true, set to false to disable prorating subscriptions
  # config.free_trial_length = 30

  # This will leave the subscription enabled until the billing period.
  # Users will be able to update their subscription to re-enable their subscription if they decide to keep it.
  # This keeps the plan record intact and the actual cancellation is handled by the webhook via the
  # customer.subscription.deleted webhook event.
  # config.cancel_at_period_end = true

  # Specify layout you want to use for the subscription pages, default is application
  config.layout = 'application'
  
  # you can subscribe to additional webhooks here
  # we use stripe_event under the hood and you can subscribe using the 
  # stripe_event syntax on the config object: 
  # config.subscribe 'charge.failed', Koudoku::ChargeFailed
  
end
