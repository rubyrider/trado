module Payatron4000

    class Paypal

        # Creates the payment information object for PayPal to parse in the login step
        #
        # @param order [Object]
        # @param steps [Array]
        # @param cart [Object]
        # @param ip_address [String]
        # @param return_url [String]
        # @param cancel_url [String]
        # @return [Object] order data from the store for PayPal
        def self.express_setup_options order, steps, cart, ip_address, return_url, cancel_url
            {
              subtotal:               Store::Price.new(order.net_amount, 'net').singularize,
              shipping:               Store::Price.new(order.delivery.price, 'net').singularize,
              tax:                    Store::Price.new(order.tax_amount, 'net').singularize,
              handling:               0,
              order_id:               order.id,
              items:                  Payatron4000::Paypal.express_items(cart),
              ip:                     ip_address,
              return_url:             return_url,
              cancel_return_url:      cancel_url,
              currency:               'GBP',
            }
        end

        # Creates the payment information object for PayPal to parse in the confirmation step and complete the purchase
        #
        # @param order [Object]
        # @return [Object] current customer order
        def self.express_purchase_options order
            {
              subtotal:          Store::Price.new(order.net_amount, 'net').singularize,
              shipping:          Store::Price.new(order.delivery.price, 'net').singularize,
              tax:               Store::Price.new(order.tax_amount, 'net').singularize,
              handling:          0,
              token:             order.express_token,
              payer_id:          order.express_payer_id,
              currency:          'GBP',
            }
        end

        # Creates an aray of items which represent cart_items
        # This is passed into the express_setup_options method
        #
        # @return [Array] list of cart items for PayPal
        def self.express_items cart
            cart.cart_items.collect do |item|
                {
                  name:             item.sku.product.name,
                  description:      "#{item.sku.attribute_value}#{item.sku.attribute_type.measurement unless item.sku.attribute_type.measurement.nil? }",
                  amount:           Store::Price.new(item.price, 'net').singularize, 
                  quantity:         item.quantity 
                }
            end
        end

        # Assign PayPal token to order after user logs into their account
        #
        # @param token [String]
        # @param payer_id [Integer]
        # @param order [Object]
        def self.assign_paypal_token token, payer_id, order
            order.express_token = token
            order.express_payer_id = payer_id
            order.save(validate: false)
        end

        # Completes the order process by communicating with PayPal; receives a response and in turn creates the relevant transaction records,
        # sends a confirmation email and redirects the user. Rollbar is notified with the relevant data if the email fails to send
        #
        # @param order [Object]
        # @param session [Object
        def self.complete order, session
          response = EXPRESS_GATEWAY.purchase(Store::Price.new(order.gross_amount, 'net').singularize, 
                                              Payatron4000::Paypal.express_purchase_options(order)
          )
          if response.success?
            begin 
              Payatron4000::Paypal.successful(response, order)
              Payatron4000::destroy_cart(session)
            rescue Exception => e
              Rollbar.report_exception(e)
            end
            order.reload
            Mailatron4000::Orders.confirmation_email(order) rescue Rollbar.report_message("Order #{order.id} confirmation email failed to send", "info", order: order)
            return Rails.application.routes.url_helpers.success_order_build_url(order_id: order.id, id: 'confirm')
          else
            begin
              Payatron4000::Paypal.failed(response, order)
            rescue Exception => e
              Rollbar.report_exception(e)
            end
            order.reload
            Mailatron4000::Orders.confirmation_email(order) rescue Rollbar.report_message("Order #{order.id} confirmation email failed to send", "info", order: order)
            return Rails.application.routes.url_helpers.failure_order_build_url(order_id: order.id, id: 'confirm')
          end
        end

        # Upon successfully completing an order with a PayPal payment option a new transaction record is created, stock is updated for the relevant SKU
        # and order status attribute set to active
        #
        # @param response [Object]
        # @param order [Object]
        def self.successful response, order
            Transaction.new
            (  
              fee:                  response.params['PaymentInfo']['FeeAmount'], 
              gross_amount:         response.params['PaymentInfo']['GrossAmount'], 
              order_id:             order.id, 
              payment_status:       response.params['PaymentInfo']['PaymentStatus'].downcase, 
              transaction_type:     'Credit', 
              tax_amount:           response.params['PaymentInfo']['TaxAmount'], 
              paypal_id:            response.params['PaymentInfo']['TransactionID'], 
              payment_type:         response.params['PaymentInfo']['TransactionType'],
              net_amount:           response.params['PaymentInfo']['GrossAmount'].to_d - response.params['PaymentInfo']['TaxAmount'].to_d,
              status_reason:        response.params['PaymentInfo']['PendingReason']
            ).save(validate: false)
            Payatron4000::update_stock(order)
            Payatron4000::increment_product_order_count(order.products)
            order.status = :active
            order.save(validate: false)
        end

        
        # When an order has failed to complete, a new transaction record is created with a logged status reason
        #
        # @param response [Object]
        # @param order [Object]
        def self.failed response, order
            Transaction.new
            (  
              fee:                  0, 
              gross_amount:         order.gross_amount, 
              order_id:             order.id, 
              payment_status:       'failed', 
              transaction_type:     'Credit', 
              tax_amount:           order.tax_amount, 
              paypal_id:            '', 
              payment_type:         'express-checkout',
              net_amount:           order.net_amount,
              status_reason:        response.message,
              error_code:           response.params["error_codes"].to_i
            ).save(validate: false)
            order.status = :active
            order.save(validate: false)
        end

    end
end