## 2.0.0 (not active on rubygems)
author: Donn Felker (@donnfelker)

This version adds support for canceling at the end of the billing period, subscription reactivation,
and various fixes for Rails 5 and more.

Enhancements: 
 
 - Subscription cancellation logic has been moved into the Subscription concern to that it is not littered about.
 - Cancel at period end: Using `Koudoku.cancel_at_period_end = true` in the allows you to utilize the cancel at period end functionality. When using this you MUST use webhooks otherwise cancellations will not process accordingly.
 - If an error occurs during processing of a plan change/etc the flow will stop via `throw(:abort)`
 - The default `stripe_event.rb` file now calls `subscription#cancel(force = true)` so that when a `customer.subscription.deleted` is received the subscription will be cancelled. 
    - The previous implementation relied on the developer to implement this and it was too easy to miss when setting up Koudoku, therefore resulting in subscriptions that were active on your site, but not on Stripe.
 - In `stripe_event.rb` the `subsription` objects are inspected before operating on them. This is useful when you use the same stripe account for other purposes other than your site. 
   - Previously, if this was not handled, the webhook would error out and stripe would continue to retry this request over and over. This can result in Stripe stopping webhook calls as they keep getting errors back from your server. This prevents that.


## Version 0.0.12 (NOT released on rubygems)
author: Christoph Engelhardt (@yas4891)

This version has a breaking change regarding webhooks.
Koudoku now uses stripe_engine under the hood.  
You need to follow these instructions even if you do NOT use webhooks: 

Go to `config/initializers/koudoku.rb` and remove the line `config.webhooks_api_key= 'XXXX'`

Please refer to the README.md under the section "webhooks" for more information on how to use the 
new webhook engine

## Master (Unreleased)

If you're upgrading from previous versions, you *must* add the following to
your `app/views/layouts/application.html.erb` before the closing of the `<head>`
tag or your credit card form will no longer work:

    <%= yield :koudoku %>
    
If you have a Haml layout file, it is:

    = yield :koudoku

## Version 0.0.9

Adding support for non-monthly plans. The default is still monthly. To
accommodate this, a `interval` attribute has been added to the `Plan` class.
To upgrade earlier installations, you can run the following commands:

    $ rails g migration add_interval_to_plan interval:string
    $ rake db:migrate
    
You'll also need to make this attribute mass-assignable:

    class Plan < ActiveRecord::Base
      include Koudoku::Plan
      attr_accessible :interval
    end
