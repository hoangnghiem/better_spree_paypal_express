require 'paypal-sdk-merchant'
module Spree
  class Gateway::PayPalExpress < Gateway
    preference :login, :string
    preference :password, :string
    preference :signature, :string
    preference :server, :string, default: 'sandbox'
    preference :solution, :string, default: 'Mark'
    preference :landing_page, :string, default: 'Billing'
    preference :logourl, :string, default: ''

    def supports?(source)
      true
    end

    def provider_class
      ::PayPal::SDK::Merchant::API
    end

    def provider
      ::PayPal::SDK.configure(
        :mode      => preferred_server.present? ? preferred_server : "sandbox",
        :username  => preferred_login,
        :password  => preferred_password,
        :signature => preferred_signature)
      provider_class.new
    end

    def auto_capture?
      true
    end

    def method_type
      'paypal'
    end

    def empty_success
      Class.new do
        def success?; true; end
        def authorization; nil; end
      end.new
    end
    

    def void(response_code, gateway_options={})
      Rails.logger.info"Voiding transction ID #{response_code}"
      payment = Spree::Payment.find_by_response_code(response_code)
      Rails.logger.info"Voiding pyament: #{payment.inspect}"
      amount = payment.credit_allowed

      #in case a partially refunded payment gets cancelled/voided, we don't want to act on the refunded payments
      if amount.to_f > 0

        # Process the refund
        refund_type = payment.amount == amount.to_f ? "Full" : "Partial"

        refund_transaction = provider.build_refund_transaction({
          :TransactionID => payment.source.transaction_id,
          :RefundType => refund_type,
          :Amount => {
            :currencyID => payment.currency,
            :value => amount },
          :RefundSource => "any" })
        
        refund_transaction_response = provider.refund_transaction(refund_transaction)

        Rails.logger.info "Refund transaction response from paypal #{refund_transaction_response.inspect}"
      
        if refund_transaction_response.success?
          payment.source.update_attributes({
            :refunded_at => Time.now,
            :refund_transaction_id => refund_transaction_response.RefundTransactionID,
            :state => "refunded",
            :refund_type => refund_type
          })
          empty_success
        else
          class << refund_transaction_response
            def to_s
              errors.map(&:long_message).join(" ")
            end
          end
          refund_transaction_response
        end
      end

      empty_success
    end

    #cancellations also work for a partially refunded payment
    def cancel(response_code)
      void(response_code, {})
    end

    def purchase(amount, express_checkout, gateway_options={})
      Rails.logger.info "Express purchase"
      Rails.logger.info "Gateway optiosn #{gateway_options}"

      pp_details_request = provider.build_get_express_checkout_details({
        :Token => express_checkout.token
      })
      pp_details_response = provider.get_express_checkout_details(pp_details_request)

      Rails.logger.info "Paypal response #{pp_details_response.inspect}"

      pp_request = provider.build_do_express_checkout_payment({
        :DoExpressCheckoutPaymentRequestDetails => {
          :PaymentAction => "Sale",
          :Token => express_checkout.token,
          :PayerID => express_checkout.payer_id,
          :PaymentDetails => pp_details_response.get_express_checkout_details_response_details.PaymentDetails
        }
      })

      pp_response = provider.do_express_checkout_payment(pp_request)
      Rails.logger.info "Paypal do express response #{pp_response.inspect}"
      if pp_response.success?
        # We need to store the transaction id for the future.
        # This is mainly so we can use it later on to refund the payment if the user wishes.
        transaction_id = pp_response.do_express_checkout_payment_response_details.payment_info.first.transaction_id
        Rails.logger.info "Paypal transaction ID #{transaction_id}"
        express_checkout.update_column(:transaction_id, transaction_id)

        #"order_id: The Order’s number attribute, plus the identifier for each payment, generated when the payment is first created"
        payment = Spree::Payment.find_by_number(gateway_options[:order_id].split('-').last)
        Rails.logger.info "Found payment #{payment.inspect}"
        payment.update_attribute(:response_code, transaction_id)

        Rails.logger.info "Save transaction ID to payment"
        Rails.logger.info "Payment #{payment.inspect}"

        empty_success
      else
        class << pp_response
          def to_s
            errors.map(&:long_message).join(" ")
          end
        end
        pp_response
      end
    end

    def refund(payment, amount)
      refund_type = payment.amount == amount.to_f ? "Full" : "Partial"
      refund_transaction = provider.build_refund_transaction({
        :TransactionID => payment.source.transaction_id,
        :RefundType => refund_type,
        :Amount => {
          :currencyID => payment.currency,
          :value => amount },
        :RefundSource => "any" })
      refund_transaction_response = provider.refund_transaction(refund_transaction)
      if refund_transaction_response.success?
        payment.source.update_attributes({
          :refunded_at => Time.now,
          :refund_transaction_id => refund_transaction_response.RefundTransactionID,
          :state => "refunded",
          :refund_type => refund_type
        })

        payment.class.create!(
          :order => payment.order,
          :source => payment,
          :payment_method => payment.payment_method,
          :amount => amount.to_f.abs * -1,
          :response_code => refund_transaction_response.RefundTransactionID,
          :state => 'completed'
        )
      end
      refund_transaction_response
    end
  end
end

#   payment.state = 'completed'
#   current_order.state = 'complete'
