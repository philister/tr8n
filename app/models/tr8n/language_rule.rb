#--
# Copyright (c) 2010-2013 Michael Berkovich, tr8nhub.com
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#++
#
#-- Tr8n::LanguageRule Schema Information
#
# Table name: tr8n_language_rules
#
#  id               INTEGER         not null, primary key
#  language_id      integer         not null
#  translator_id    integer         
#  type             varchar(255)    
#  definition       text            
#  created_at       datetime        not null
#  updated_at       datetime        not null
#
# Indexes
#
#  tr8n_lr_lt    (language_id, translator_id) 
#  tr8n_lr_l     (language_id) 
#
#++

class Tr8n::LanguageRule < ActiveRecord::Base
  self.table_name = :tr8n_language_rules
  attr_accessible :language_id, :translator_id, :definition, :keyword
  attr_accessible :language, :translator

  after_save      :clear_cache
  after_destroy   :clear_cache

  belongs_to :language, :class_name => "Tr8n::Language"   
  belongs_to :translator, :class_name => "Tr8n::Translator"   
  
  serialize :definition

  def self.config
    Tr8n::Config.rules_engine
  end

  def self.to_api_hash(opts = {})
    hash = {:type => keyword}.merge(config)
    if opts[:language]
      hash[:rules] = []
      where(:language_id => opts[:language].id).each do |lr|
        hash[:rules] << lr.to_api_hash
      end
    end
    hash
  end

  def self.rule_for_keyword_and_language(keyword, language = Tr8n::Config.current_language)
    self.where("language_id = ? and keyword = ?", language.id, keyword).first
  end

  def self.cache_key(rule_id)
    "language_rule_[#{rule_id}]"
  end

  def cache_key
    self.class.cache_key(self.id)
  end

  def definition
    @indifferent_def ||= HashWithIndifferentAccess.new(super)
  end

  def self.by_id(rule_id)
    Tr8n::Cache.fetch(cache_key(rule_id)) do 
      find_by_id(rule_id)
    end
  end
  
  def self.for(language)
    self.where("language_id = ?", language.id).all
  end
  
  def self.options
    @options ||= Tr8n::Config.language_rule_classes.collect{|kls| [kls.dependency_label, kls.name]}
  end

  def self.suffixes
    []  
  end
  
  def self.dependant?(token)
    token.dependency == dependency or suffixes.include?(token.suffix)
  end

  def self.keyword
    dependency
  end

  # TDOD: switch to using keyword
  def self.dependency
    raise Tr8n::Exception.new("This method must be implemented in the extending rule") 
  end
  
  # TDOD: switch to using keyword
  def self.dependency_label
    dependency
  end

  def self.sanitize_values(values)
    return [] unless values
    values.split(",").collect{|val| val.strip} 
  end
  
  def self.humanize_values(values)
    sanitize_values(values).join(", ")
  end

  def evaluate(token_value)
    raise Tr8n::Exception.new("This method must be implemented in the extending rule") 
  end
  
  def description
    raise Tr8n::Exception.new("This method must be implemented in the extending rule") 
  end
  
  def token_description
    raise Tr8n::Exception.new("This method must be implemented in the extending rule") 
  end
  
  def self.transformable?
    true
  end

  def self.transform_params_to_options(params)
    raise Tr8n::Exception.new("This method must be implemented in the extending rule") 
  end

  def self.transform(token, object, params, language)
    if params.empty?
      raise Tr8n::Exception.new("Invalid form for token #{token}")
    end

    options = transform_params_to_options(params)

    matched_key = nil
    options.keys.each do |key|
      next if key == :other  # other is a special keyword - don't process it
      rule = rule_for_keyword_and_language(key, language)
      unless rule
        raise Tr8n::Exception.new("Invalid rule name #{key} for transform token #{token}")
      end

      if rule.evaluate(object)
        matched_key = key.to_sym
        break
      end
    end

    unless matched_key
      return options[:other] if options[:other]
      raise Tr8n::Exception.new("No rules matched for transform token #{token} : #{options.inspect} : #{object}")
    end

    options[matched_key]
  end

  def save_with_log!(new_translator)
    if self.id
      if changed?
        self.translator = new_translator
        translator.updated_language_rule!(self)
      end
    else  
      self.translator = new_translator
      translator.added_language_rule!(self)
    end

    save  
  end
  
  def destroy_with_log!(new_translator)
    new_translator.deleted_language_rule!(self)
    
    destroy
  end

  def clear_cache
    Tr8n::Cache.delete(cache_key)
  end

  ###############################################################
  ## Synchronization Methods
  ###############################################################
  # {"locale"=>"ru", "label"=>"{count} сообщения", "rank"=>1, "rules"=>[
  #        {"token"=>"count", "type"=>"number", "definition"=>
  #             {"multipart"=>true, "part1"=>"ends_in", "value1"=>"2,3,4", "operator"=>"and", "part2"=>"does_not_end_in", "value2"=>"12,13,14"}
  #        }
  #     ]
  # }

  def to_api_hash(opts = {})
    if opts[:token]
      return {
        "token" => opts[:token],
        "type" => self.class.keyword,
        "keyword" => keyword,
        "definition" => definition,
      }
    end

    definition.merge(:keyword => keyword)
  end
  
  def self.create_from_sync_hash(lang, translator, rule_hash, opts = {})
    return unless rule_hash["token"] and rule_hash["type"] and rule_hash["definition"]

    rule_class = Tr8n::Config.language_rule_dependencies[rule_hash["type"]]
    return unless rule_class # unsupported rule type, skip this completely
    
    rule_class.for(lang).each do |rule|
      return rule if rule.definition == rule_hash["definition"]
    end
    
    rule_class.create(:language => lang, :translator => translator, :definition => rule_hash["definition"])
  end


end
