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
          documents.each do |proj, roles|
            log.debug "proj: #{proj}, params: #{roles.inspect}"
            if roles.empty?
              log.error("no params for #{proj}")
            else
              result[proj] = {}
              roles.each do |role, params|
                result[proj][role] = params.select do |k, _|
                  %w[branch release_timestamp current_revision deploy_user].include?(k)
                end
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

        log.info data.force_encoding('utf-8').to_json

        [data, error]
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

          deployment[project].each do |role, params|
            params['release_timestamp'] = DateTime.parse(params['release_timestamp']).to_time
            params = params.sort
            msg[:fields] << {
              title: "Role #{'-' * 30}",
              value: role,
              short: false
            }

            params.each do |key, value|
              msg[:fields] << {
                title: key.capitalize,
                value: value,
                short: true
              }
            end
          end
        else
          msg[:title] = env

          deployment.each do |proj, roles|
            msg[:fields] << {
              title: "Project #{'-' * 50}",
              value: proj.capitalize,
              short: false
            }

            roles.each do |role, params|
              params['release_timestamp'] = DateTime.parse(params['release_timestamp']).to_time
              params = params.sort

              msg[:fields] << {
                title: "Role #{'-' * 30}",
                value: role,
                short: false
              }

              params.each do |key, value|
                msg[:fields] << {
                  title: key.capitalize,
                  value: value,
                  short: true
                }
              end
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
          deployment[data[:project]].each do |role, params|
            msg[:fields] << {
              title: [data[:project], role].uniq.join(' - '),
              value: params['branch'],
              short: false
            }
          end
        else
          text << '```'

          deployment.each do |proj, roles|
            roles.each do |role, params|
              text << "#{[proj, role].uniq.join(' - ').ljust(25)} - #{params['branch']}\n"
            end
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
        message = "Environment: #{data[:environment]}\n"

        if data[:project]
          project = data[:project]
          deployment[project].each do |role, params|
            message << "Role: #{role}, "
            message << "Branch: #{params['branch']}, "
            message << "Commit: #{params['current_revision']}, "
            message << "Deployer: #{params['deploy_user']}, "
            message << "Date: #{params['release_timestamp']}\n"
          end
        else
          deployment.each do |proj, roles|
            message << "Project: #{proj}\n"
            roles.each do |role, params|
              message << "Role: #{role}, "
              message << "Branch: #{params['branch']}, "
              message << "Commit: #{params['current_revision']}, "
              message << "Deployer: #{params['deploy_user']}, "
              message << "Date: #{params['release_timestamp']}\n"
            end
          end
        end

        message
      end
    end
  end
end

