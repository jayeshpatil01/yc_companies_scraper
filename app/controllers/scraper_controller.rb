require 'selenium-webdriver'
require 'nokogiri'

class ScraperController < ApplicationController
  BASE_URL = 'https://www.ycombinator.com/companies'
  MAX_RETRIES = 2

  before_action :initialize_scraper

  def index
    @n = params[:n].present? && params[:n].to_i > 0 ? params[:n].to_i : 60

    load_page
    collect_companies

    render json: @companies
  ensure
    @driver.quit
  end

  private

  def initialize_scraper
    @companies = []
    @driver = driver_setup
    @wait = Selenium::WebDriver::Wait.new(timeout: 10) # Set an explicit wait timeout
  end
  
  def driver_setup
    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    Selenium::WebDriver.for :chrome, options: options
  end
  
  def load_page
    @driver.navigate.to BASE_URL
    @wait.until { @driver.find_element(css: '._company_86jzd_338') }
  end

  def collect_companies
    retry_count = 0
    begin
      company_cards = []
      while @companies.size < @n
        old_size = company_cards.size
        @driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")

        @wait.until do
          company_cards = @driver.find_elements(css: '._company_86jzd_338')
          company_cards.size > old_size
        end

        company_cards.each_with_index do |company_card, index|
          break if @companies.size >= @n
          company = extract_company_info(company_card)
          details_link = company_card.attribute('href')
          fetch_company_details(details_link, company)

          @companies << company

          # Close the details tab and switch back to the main tab
          @driver.close
          @driver.switch_to.window(@driver.window_handles.first)

          # Re-fetch the company cards to ensure the references are valid
          # Limit to re-fetch only up to the current index to avoid re-processing
          company_cards = @driver.find_elements(css: '._company_86jzd_338').first(index + 1)
        end
      end

    rescue Selenium::WebDriver::Error::NoSuchElementError => e
      Rails.logger.error("Element not found: #{e.message}")
      retry_count += 1
      retry if retry_count < MAX_RETRIES
    rescue Selenium::WebDriver::Error::StaleElementReferenceError => e
      Rails.logger.error("Stale element reference: #{e.message}")
      retry_count += 1
      retry if retry_count < MAX_RETRIES
    rescue Selenium::WebDriver::Error::InvalidSessionIdError => e
      Rails.logger.error("Invalid session ID: #{e.message}")
      retry_count += 1
      retry if retry_count < MAX_RETRIES
    end
  end

  def extract_company_info(company_card)
    {
      name: company_card.find_element(css: '._coName_86jzd_453').text.strip,
      location: company_card.find_element(css: '._coLocation_86jzd_469').text.strip,
      description: company_card.find_element(css: '._coDescription_86jzd_478').text.strip,
      yc_batch: company_card.find_element(css: '._tagLink_86jzd_1023 span').text.strip
    }
  end

  def fetch_company_details(url, company)
    retry_count = 0
    begin
      # Open the company details page in a new tab
      @driver.execute_script("window.open(arguments[0], '_blank');", url)
      @driver.switch_to.window(@driver.window_handles.last)
      @wait.until { @driver.find_element(css: '.leading-none.text-linkColor a') }

      page = Nokogiri::HTML(@driver.page_source)

      company[:company_website] = page.at_css('.leading-none.text-linkColor a')['href']
      company[:founders] = page.css('div.leading-snug').map { |ele| ele.text.strip }
      company[:linkedin_profiles] = []
      page.css('div.leading-snug a[title="LinkedIn profile"]').each do |link|
        company[:linkedin_profiles] << link['href']
      end
    rescue Selenium::WebDriver::Error::StaleElementReferenceError => e
      Rails.logger.error("Stale element reference: #{e.message}")
      retry_count += 1
      retry if retry_count < MAX_RETRIES
    end
  end
end
