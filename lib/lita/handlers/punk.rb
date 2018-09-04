require 'json'
require 'date'
require 'elasticsearch'

module Lita
  module Handlers
    class Punk < Handler
      config :es_host, type: String, default: '127.0.0.1'
      config :es_port, type: Integer, default: 9200
      config :es_log,  types: [TrueClass, FalseClass], default: false

      route(/cho(\s+)(.+)$/i, :get_deployment, command: true, help: {
        'cho <environment>'               => 'Returns deployed version of all projects in <environment>',
        'cho <environment> ext'           => 'Returns deployed version of all projects in <environment> with extended info',
        'cho <environment> <project>'     => 'Returns deployed version for <project> in <environment>',
        'cho <environment> <project> ext' => 'Returns deployed version for <project> in <environment> with extended info',
      })

      def es
        @@es ||= Elasticsearch::Client.new(
          url: "#{config.es_host}:#{config.es_port}",
          log: config.es_log
        )
      end

      def get_deployment(response)
        data, err = prepare_data(response)

        if err
          response.reply(err)
          return
        end

        deployment = search(data[:environment])

        if deployment.empty?
          response.reply("nothing found for environment `#{data[:environment]}`")
          return
        end

        if data[:project] && !deployment[data[:project]]
          response.reply("no entry for #{data[:project]} found")
          return
        end

        if data[:extended]
          response.reply(simple_message(data, deployment)) unless slack_message_ext(data, deployment)
        else
          response.reply(simple_message(data, deployment)) unless slack_message(data, deployment)
        end
      end

      Lita.register_handler(self)

      private

      def blank?(str)
        str.strip.empty?
      end

      def search(env)
        result = {}
        begin
          documents = es.search(index: 'capistrano', body: { query: { match: { _id: env }}})['hits']['hits']
                        .map{ |p| p['_source']['apps_v2'] }
                        .inject(:merge)
        rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Net::ReadTimeout => e
          log.error("can't search in elastic due: #{e.message}")
        end

        if documents
          documents.each do |proj, params|
            log.debug "proj: #{proj}, params: #{params.inspect}"
            if params.empty?
              log.error("no params for #{proj}")
            else
              result[proj] = params.map { |k, v| v }.inject(:merge).select do |k, _|
                %w[branch release_timestamp current_revision deploy_user].include?(k)
              end
            end
          end
        end
        result
      end

      def prepare_data(response)
        data           = {}
        error          = false
        data[:user]    = response.user.name
        data[:message] = response.message.body
        data[:target]  = response.room
        matches        = response.matches.first.last.split

        if matches.count == 1
          data[:environment] = matches.first
        elsif matches.count == 2 && matches.last == 'ext'
          data[:environment] = matches.first
          data[:extended]    = true
        elsif matches.count == 2
          data[:environment] = matches.first
          data[:project]     = matches.last
        elsif matches.count == 3 && matches.last == 'ext'
          data[:extended]    = true
          data[:environment] = matches[0]
          data[:project]     = matches[1]
        else
          error = 'wrong arguments'
        end

        log.info data.to_json

        return data, error
      end

      def slack_message_ext(data, deployment)
        msg          = {}
        msg[:color]  = "#FFCA06"
        env          = data[:environment]
        msg[:footer] = 'Based on information from elasticsearch'
        msg[:fields] = []


        if data[:project]
          project     = data[:project]
          msg[:title] = "#{env} - #{project}"

          deployment[project]['release_timestamp'] = DateTime.parse(deployment[project]['release_timestamp']).to_time
          deployment[project] = deployment[project].sort

          deployment[project].each do |key, value|
            msg[:fields] << {
              title: key.capitalize,
              value: value,
              short: true
            }
          end
        else
          msg[:title] = env

          deployment.each do |proj, vals|
            vals['release_timestamp'] = DateTime.parse(vals['release_timestamp']).to_time
            vals = vals.sort

            msg[:fields] << {
              title: "Project #{'-' * 50}",
              value: proj.capitalize,
              short: false
            }
            vals.each do |key, value|
              msg[:fields] << {
                title: key.capitalize,
                value: value,
                short: true
              }
            end
          end
        end

        begin
          attachment = Lita::Adapters::Slack::Attachment.new('', msg)
          robot.chat_service.send_attachment(data[:target], attachment)
          return true
        rescue StandardError => e
          log.error("can't send slack message due: #{e.message}")
          return false
        end
      end

      def slack_message(data, deployment)
        msg           = {}
        msg[:color]   = "#FFCA06"
        msg[:pretext] = "*#{data[:environment]}*"
        text          = ''
        msg[:footer]  = 'Based on information from elasticsearch'

        if data[:project]
          msg[:fields] = []
          msg[:fields] << {
            title: data[:project],
            value: deployment[data[:project]]['branch'],
            short: false
          }
        else
          text << '```'

          deployment.each do |proj, vals|
            text << "#{proj.ljust(25)} - #{vals['branch']}\n"
          end

          text << '```'
        end

        begin
          attachment = Lita::Adapters::Slack::Attachment.new(text, msg)
          robot.chat_service.send_attachment(data[:target], attachment)
          return true
        rescue StandardError => e
          log.error("can't send slack message due: #{e.message}")
          return false
        end
      end

      def simple_message(data, deployment)
        message = ''

        if data[:project]
          project = data[:project]
          message = "Environment: #{data[:environment]}, "
          message << "Branch: #{deployment[project]['branch']}, "
          message << "Commit: #{deployment[project]['current_revision']}, "
          message << "Deployer: #{deployment[project]['deploy_user']}, "
          message << "Date: #{deployment[project]['release_timestamp']}"
        else
          message = "Environment: #{data[:environment]}\n"

          deployment.each do |proj, vals|
            message << "Project: #{proj}\n"
            message << "Branch: #{vals['branch']}, "
            message << "Commit: #{vals['current_revision']}, "
            message << "Deployer: #{vals['deploy_user']}, "
            message << "Date: #{vals['release_timestamp']}\n"
          end
        end

        return message
      end
    end
  end
end

