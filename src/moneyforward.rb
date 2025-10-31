# frozen_string_literal: true
require "csv"
require "http-cookie"

class MoneyForwardClient
  def initialize(cookies_txt_path)
    Console.info("Logging in to Money Forward account...")
    @client = build_client(cookies_txt_path)
    @mail = fetch_mail
    Console.info("Logged in as #{@mail}")

    @categories = nil

    load_categories
  end

  def fetch_history(wallet_id, year:, month:)
    from = "#{year}/#{format("%02d", month)}/01"
    response =
      @client.encoding(Encoding::BINARY).get(
        "https://moneyforward.com/cf/csv",
        params: {
          account_id_hash: wallet_id,
          from: from,
          month: month,
          service_id: 0,
          year: year
        }
      )
    raise "Failed to fetch history" unless response.status.success?
    csv =
      response
        .body
        .to_s
        .force_encoding(Encoding::Shift_JIS)
        .encode(Encoding::UTF_8)
    parsed = CSV.parse(csv, headers: true)
    parsed.map do |row|
      {
        date: Date.parse(row["日付"]),
        description: row["内容"],
        amount: row["金額（円）"].gsub(",", "").to_i,
        category_large: row["大項目"],
        category_medium: row["中項目"],
        memo: row["メモ"]
      }
    end
  end

  def expense_categories
    @expense_large_categories.map do |large_cat|
      {
        large_category: large_cat[:name],
        medium_categories:
          @expense_medium_categories
            .select { |m| m[:large_category_id] == large_cat[:id] }
            .map { |m| m[:name] }
      }
    end
  end

  def income_categories
    @income_large_categories.map do |large_cat|
      {
        large_category: large_cat[:name],
        medium_categories:
          @income_medium_categories
            .select { |m| m[:large_category_id] == large_cat[:id] }
            .map { |m| m[:name] }
      }
    end
  end

  def create_expense_transaction(
    wallet_id,
    large_category:,
    medium_category:,
    date:,
    description:,
    amount:
  )
    create_transaction(
      wallet_id: wallet_id,
      large_categories: @expense_large_categories,
      medium_categories: @expense_medium_categories,
      category_scope: "expense",
      large_category: large_category,
      medium_category: medium_category,
      date: date,
      description: description,
      amount: -amount,
      income: false
    )
  end

  def create_income_transaction(
    wallet_id,
    large_category:,
    medium_category:,
    date:,
    description:,
    amount:
  )
    create_transaction(
      wallet_id: wallet_id,
      large_categories: @income_large_categories,
      medium_categories: @income_medium_categories,
      category_scope: "income",
      large_category: large_category,
      medium_category: medium_category,
      date: date,
      description: description,
      amount: amount,
      income: true
    )
  end

  private

  def create_transaction(
    wallet_id:,
    large_categories:,
    medium_categories:,
    category_scope:,
    large_category:,
    medium_category:,
    date:,
    description:,
    amount:,
    income:
  )
    large_category_obj =
      large_categories.find { |lc| lc[:name] == large_category }
    unless large_category_obj
      raise "Invalid #{category_scope} category, large_category: #{large_category} not found"
    end
    medium_category_obj =
      medium_categories.find do |mc|
        mc[:name] == medium_category &&
          mc[:large_category_id] == large_category_obj[:id]
      end
    unless medium_category_obj
      raise "Invalid #{category_scope} category, medium_category: #{medium_category} not found"
    end

    wallet_page =
      @client.get("https://moneyforward.com/accounts/show_manual/#{wallet_id}")
    raise "Failed to get wallet page" unless wallet_page.status.success?
    wallet_doc = Nokogiri.HTML(wallet_page.to_s)
    csrf_token = wallet_doc.at_css('meta[name="csrf-token"]')["content"]
    wallet_account_id_option =
      wallet_doc.at_css(
        '#user_asset_act_sub_account_id_hash > option[selected="selected"]'
      )
    Console.info(
      "Creating #{income ? "income" : "expense"} transaction on #{date} for #{amount} yen in wallet #{
        wallet_account_id_option.text.match(/^(.*) \([-0-9,]+円\)$/)[1].strip
      }..."
    )
    wallet_account_id_hash = wallet_account_id_option["value"]

    create_response =
      @client.headers("X-CSRF-Token" => csrf_token).post(
        "https://moneyforward.com/cf/create",
        form: {
          "authenticity_token" => csrf_token,
          "user_asset_act[is_transfer]" => "0",
          "user_asset_act[is_income]" => income ? "1" : "0",
          "user_asset_act[payment]" => "2",
          "user_asset_act[updated_at]" => date.strftime("%Y/%m/%d"),
          "month" => date.strftime("%Y-%m"),
          "user_asset_act[amount]" => amount.to_s,
          "user_asset_act[sub_account_id_hash]" => wallet_account_id_hash,
          "user_asset_act[large_category_id]" => large_category_obj[:id].to_s,
          "user_asset_act[middle_category_id]" => medium_category_obj[:id].to_s,
          "user_asset_act[content]" => description
        }
      )
    raise "Failed to create transaction" unless create_response.status.success?
    unless create_response.body.to_s == "setTimeout('location.reload()',500);"
      raise "Unexpected response body: #{create_response.body}"
    end
  end

  def build_client(cookies_txt_path)
    client = HTTP::Client.new.follow(strict: false)
    cookie_jar = HTTP::CookieJar.new
    cookie_jar.load(cookies_txt_path, format: :cookiestxt)
    client.cookies(cookie_jar)
  end

  def fetch_mail
    id_page = @client.get("https://id.moneyforward.com/me")
    raise "Failed to get ID page" unless id_page.status.success?
    id_page.body.to_s.match(/gon\.headerDisplayName="([^"]+)"/)[1]
  end

  def load_categories
    index = @client.get("https://moneyforward.com/cf")
    raise "Failed to get index page" unless index.status.success?
    index_doc = Nokogiri.HTML(index.to_s)
    income = index_doc.at_css(".dropdown-menu.main_menu.plus")
    expense = index_doc.at_css(".dropdown-menu.main_menu.minus")
    @expense_large_categories =
      expense
        .css("a.l_c_name")
        .map { |a| { id: a["id"].to_i, name: a.text.strip } }
    @expense_medium_categories =
      expense
        .css("a.m_c_name")
        .map do |a|
          {
            id: a["id"].to_i,
            name: a.text.strip,
            large_category_id: a.parent.parent["id"].to_i
          }
        end
    @income_large_categories =
      income
        .css("a.l_c_name")
        .map { |a| { id: a["id"].to_i, name: a.text.strip } }
    @income_medium_categories =
      income
        .css("a.m_c_name")
        .map do |a|
          {
            id: a["id"].to_i,
            name: a.text.strip,
            large_category_id: a.parent.parent["id"].to_i
          }
        end
  end
end
