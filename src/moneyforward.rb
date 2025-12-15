# frozen_string_literal: true
require "date"
require "csv"
require "http-cookie"

class MoneyForwardClient
  Transaction =
    Struct.new(
      :date,
      :description,
      :amount,
      :category_large,
      :category_medium,
      :memo,
      keyword_init: true
    ) do
      def income?
        amount.positive?
      end

      def expense?
        amount.negative?
      end

      def category
        return nil unless category_large || category_medium

        { large: category_large, medium: category_medium }
      end

      def self.normalize_category(category)
        defaults = { large: "未分類", medium: "未分類" }.freeze
        return defaults if category.nil? || category.empty?

        normalized =
          category.each_with_object({}) do |(key, value), memo|
            next if value.nil? || value.to_s.strip.empty?

            case key.to_s
            when "large", "large_category"
              memo[:large] = value
            when "medium", "medium_category"
              memo[:medium] = value
            end
          end
        defaults.merge(normalized)
      end
    end

  def initialize(cookies_txt_path)
    Console.info(self, "Logging in to Money Forward account...")
    @client = build_client(cookies_txt_path)
    @mail = login(cookies_txt_path)
    Console.info(self, "Logged in as #{@mail}")

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
      Transaction.new(
        date: Date.parse(row["日付"]),
        description: row["内容"],
        amount: row["金額（円）"].gsub(",", "").to_i,
        category_large: row["大項目"],
        category_medium: row["中項目"],
        memo: row["メモ"]
      )
    end
  end

  def sync(wallet_id, transactions)
    today = Date.today
    previous_month = today.prev_month
    histories = [
      *fetch_history(
        wallet_id,
        year: previous_month.year,
        month: previous_month.month
      ),
      *fetch_history(wallet_id, year: today.year, month: today.month)
    ].sort_by(&:date)

    Array(transactions).compact.each do |transaction|
      unless transaction.is_a?(Transaction)
        raise ArgumentError,
              "MoneyForward transactions are required (got #{transaction.class})"
      end

      if transaction.date < previous_month.beginning_of_month
        Console.info(self, "Skipping old transaction on #{transaction.date}")
        next
      end

      if transaction.income?
        category = Transaction.normalize_category(transaction.category)
        match =
          histories.delete_if_first do |history|
            history.date == transaction.date &&
              history.amount == transaction.amount
          end
        if match
          Console.info(
            self,
            "Found matching Money Forward transaction for charge on #{transaction.date}, skipping..."
          )
        else
          Console.info(
            self,
            "Could not find matching transaction for charge on #{transaction.date}, creating income transaction..."
          )
          create_income_transaction(
            wallet_id,
            large_category: category[:large],
            medium_category: category[:medium],
            date: transaction.date,
            description: transaction.description,
            amount: transaction.amount
          )
        end
      else
        unless transaction.expense?
          Console.warn(
            self,
            "Transaction amount is zero for #{transaction.description} on #{transaction.date}, skipping..."
          )
          next
        end

        description = transaction.description
        unless description && !description.empty?
          Console.warn(
            self,
            "Unrecognized transaction description: #{transaction.description.inspect}, skipping..."
          )
          next
        end
        category = Transaction.normalize_category(transaction.category)
        match =
          histories.delete_if_first do |history|
            history.date == transaction.date &&
              history.amount == transaction.amount &&
              history.description.include?(description)
          end
        if match
          Console.info(
            self,
            "Found matching Money Forward transaction for #{description} on #{transaction.date}, skipping..."
          )
        else
          Console.info(
            self,
            "Could not find matching transaction for #{description} on #{transaction.date}, creating expense transaction..."
          )
          create_expense_transaction(
            wallet_id,
            large_category: category[:large],
            medium_category: category[:medium],
            date: transaction.date,
            description: description,
            amount: transaction.amount.abs
          )
        end
      end
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
      self,
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
    unless cookie_jar.cookies().find{ |c| c.name == "_mfid_session" }
      raise "Invalid or expired cookies (no _mfid_session found)"
    end
    client.cookies(cookie_jar)
  end

  def login(cookies_txt_path)
    id_page = @client.get("https://id.moneyforward.com/me")
    raise "Failed to get ID page" unless id_page.status.success?
    maybe_mail = id_page.body.to_s.match(/gon\.headerDisplayName="([^"]+)"/)
    raise "Failed to extract mail from ID page" unless maybe_mail
    new_cookies = HTTP::CookieJar.new
    new_cookies.load(cookies_txt_path, format: :cookiestxt)
    id_page.cookies.each do |cookie|
      new_cookies.add(cookie)
    end
    new_cookies.save(cookies_txt_path, format: :cookiestxt)

    maybe_mail[1]
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
