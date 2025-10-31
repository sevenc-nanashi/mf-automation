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

paseli_client = PaseliClient.new(paseli_id, paseli_password)
mf_client = MoneyForwardClient.new(moneyforward_cookies)
today = Date.today
previous_month = today.prev_month
mf_histories =
  [
    *mf_client.fetch_history(
      moneyforward_wallet_id,
      year: previous_month.year,
      month: previous_month.month
    ),
    *mf_client.fetch_history(
      moneyforward_wallet_id,
      year: today.year,
      month: today.month
    )
  ].sort_by { |h| h[:date] }

paseli_client.history.each do |paseli_tx|
  if paseli_tx[:date] < previous_month.beginning_of_month
    Console.info("Skipping old transaction on #{paseli_tx[:date]}")
    next
  end
  is_charge = paseli_tx[:description] == "チャージ"
  if is_charge
    mf_history =
      mf_histories.delete_if_first do |h|
        h[:date] == paseli_tx[:date] && h[:amount] == paseli_tx[:amount]
      end
    if mf_history
      Console.info(
        "Found matching Money Forward transaction for charge on #{paseli_tx[:date]}, skipping..."
      )
    else
      Console.info(
        "Could not find matching transaction for charge on #{paseli_tx[:date]}, creating income transaction..."
      )
      mf_client.create_income_transaction(
        moneyforward_wallet_id,
        large_category: "未分類",
        medium_category: "未分類",
        date: paseli_tx[:date],
        description: "チャージ",
        amount: paseli_tx[:amount]
      )
    end
  else
    description = paseli_tx[:description].match(/支払い\((.+?)\)/)
    unless description
      Console.warn(
        "Unrecognized transaction description: #{paseli_tx[:description]}, skipping..."
      )
      next
    end
    description = description[1]
    mf_history =
      mf_histories.delete_if_first do |h|
        h[:date] == paseli_tx[:date] && -h[:amount] == paseli_tx[:amount] &&
          h[:description].include?(description)
      end
    if mf_history
      Console.info(
        "Found matching Money Forward transaction for #{description} on #{paseli_tx[:date]}, skipping..."
      )
    else
      Console.info(
        "Could not find matching transaction for #{description} on #{paseli_tx[:date]}, creating expense transaction..."
      )
      mf_client.create_expense_transaction(
        moneyforward_wallet_id,
        large_category: "趣味・娯楽",
        medium_category: "映画・音楽・ゲーム",
        date: paseli_tx[:date],
        description: description,
        amount: paseli_tx[:amount]
      )
    end
  end
end
