# frozen_string_literal: true
require "dotenv/load"
require "console"
require_relative "paseli"
require_relative "moneyforward"
require_relative "utils"

paseli_id = ENV.fetch("PASELI_ID")
paseli_password = ENV.fetch("PASELI_PASSWORD")
moneyforward_wallet_id = ENV.fetch("MONEYFORWARD_WALLET_ID")
moneyforward_cookies = ENV.fetch("MONEYFORWARD_COOKIES")

mf_client = MoneyForwardClient.new(moneyforward_cookies)
paseli_client = PaseliClient.new(paseli_id, paseli_password)
paseli_transactions = paseli_client.history
moneyforward_transactions = paseli_transactions.map(&:to_mf).compact
mf_client.sync(moneyforward_wallet_id, moneyforward_transactions)
