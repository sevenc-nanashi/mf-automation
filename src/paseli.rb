# frozen_string_literal: true
require "date"
require "http"
require "nokogiri"
require "console"
require "console/compatible/logger"
require_relative "const"
require_relative "moneyforward"

class PaseliClient
  INCOME_CATEGORY = { large: "未分類", medium: "未分類" }.freeze
  EXPENSE_CATEGORY = { large: "趣味・娯楽", medium: "映画・音楽・ゲーム" }.freeze

  Transaction =
    Struct.new(:date, :description, :amount, keyword_init: true) do
      def charge?
        description == "チャージ"
      end

      def to_mf
        case description
        when "チャージ"
          MoneyForwardClient::Transaction.new(
            date: date,
            description: "チャージ",
            amount: amount,
            category_large: INCOME_CATEGORY[:large],
            category_medium: INCOME_CATEGORY[:medium]
          )
        when /\A支払い\((.+?)\)\z/
          MoneyForwardClient::Transaction.new(
            date: date,
            description: Regexp.last_match(1),
            amount: -amount,
            category_large: EXPENSE_CATEGORY[:large],
            category_medium: EXPENSE_CATEGORY[:medium]
          )
        else
          Console.warn(
            self,
            "Unrecognized transaction description: #{description}, skipping..."
          )
          nil
        end
      end
    end

  def initialize(username, password)
    @client = build_client
    Console.info(self, "Logging in to PASELI account...")
    establish_login_cookie
    login_doc = retrieve_login_page
    csrf_token = extract_csrf_token(login_doc)
    perform_login(username, password, csrf_token)
    @user_name = fetch_user_name
    Console.info(self, "Logged in as #{@user_name}")
  end

  def current_balance
    balance_page = @client.get("https://paseli.konami.net/charge/top.html")
    unless balance_page.status.success?
      raise "Failed to get balance page, code: #{balance_page.status.code}"
    end
    @client = @client.cookies(balance_page.cookies)

    balance_page_html = balance_page.to_s
    balance_doc = Nokogiri.HTML(balance_page_html)
    # li.remain:nth-child(1) > div:nth-child(2)
    balance_text =
      balance_doc.at_css("li.remain:nth-child(1) > div:nth-child(2)").text
    point_text =
      balance_doc.at_css("li.remain:nth-child(3) > div:nth-child(2)").text
    balance = balance_text.delete_suffix("円").gsub(",", "").to_i
    points = point_text.delete_suffix("ポイント").gsub(",", "").to_i
    { balance: balance, points: points }
  end

  def history
    history_page = @client.get("https://paseli.konami.net/charge/his01.html")
    raise "Failed to get history page" unless history_page.status.success?
    @client = @client.cookies(history_page.cookies)
    history_page_html = history_page.body.to_s
    history_doc = Nokogiri.HTML(history_page_html)
    history_table = history_doc.at_css("#ajax_body > dl:nth-child(2)")
    history_elements = history_table.css("dd")
    history_elements
      .each_slice(4)
      .map do |date_el, desc_el, amount_el, _details_el|
        date = date_el.text.strip
        description = desc_el.text.strip
        amount_text = amount_el.text.strip
        amount = amount_text.delete_suffix("円").gsub(",", "").to_i
        Transaction.new(date: Date.parse(date), description:, amount: amount)
      end
  end

  private

  def build_client
    HTTP::Client.new.headers("User-Agent" => USER_AGENT)
  end

  def establish_login_cookie
    login_cookie = @client.get("https://paseli.konami.net/charge")
    unless login_cookie.status.success?
      raise "Failed to initialize login cookie"
    end
    @client = @client.cookies(login_cookie.cookies)
  end

  def retrieve_login_page
    login_page =
      @client.follow(strict: false).get(
        "https://paseli.konami.net/charge/login.html"
      )
    raise "Failed to get login page" unless login_page.status.success?
    @client = @client.cookies(login_page.cookies)
    Nokogiri.HTML(login_page.to_s)
  end

  def extract_csrf_token(login_doc)
    token = login_doc.at_css('input[name="csrfmiddlewaretoken"]')["value"]
    Console.debug(self, "CSRF Token: #{token}")
    token
  end

  def perform_login(username, password, csrf_token)
    login_response =
      @client.headers(
        "Referer" => "https://account.konami.net/auth/login.html"
      ).post(
        "https://account.konami.net/auth/login.html",
        form: {
          "csrfmiddlewaretoken" => csrf_token,
          "userId" => username,
          "password" => password,
          "otpass" => ""
        }
      )
    raise "Failed to login" unless login_response.status.redirect?
    @client = @client.cookies(login_response.cookies)
    next_url = login_response.headers["Location"].to_s
    redirect_response = @client.get(next_url)
    unless redirect_response.status.redirect?
      raise "Failed to follow redirect after login"
    end
    @client = @client.cookies(redirect_response.cookies)
  end

  def fetch_user_name
    top = @client.get("https://paseli.konami.net/charge/top.html")
    raise "Failed to get top page" unless top.status.success?
    @client = @client.cookies(top.cookies)
    top_doc = Nokogiri.HTML(top.to_s)
    top_doc.at_css("#header_user > div > strong").text.strip
  end
end
