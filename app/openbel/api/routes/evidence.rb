require 'bel'
require 'cgi'
require 'openbel/api/evidence/mongo'
require 'openbel/api/evidence/facet_filter'
require_relative '../resources/evidence_transform'
require_relative '../helpers/pager'

module OpenBEL
  module Routes

    class Evidence < Base
      include OpenBEL::Evidence::FacetFilter
      include OpenBEL::Resource::Evidence
      include OpenBEL::Helpers

      def initialize(app)
        super

        mongo = OpenBEL::Settings[:evidence_store][:mongo]
        @api  = OpenBEL::Evidence::Evidence.new(mongo)

        # RdfRepository using Jena
        @rr = BEL::RdfRepository.plugins[:jena].create_repository(
          :tdb_directory => OpenBEL::Settings[:resource_rdf][:jena][:tdb_directory]
        )

        # Annotations using RdfRepository
        annotations = BEL::Resource::Annotations.new(@rr)

        @annotation_transform = AnnotationTransform.new(annotations)
        @annotation_grouping_transform = AnnotationGroupingTransform.new
      end

      helpers do

        def stream_evidence_objects(cursor)

          stream :keep_open do |response|
            cursor.each do |evidence|
              evidence.delete('facets')

              response << render_resource(
                  evidence,
                  :evidence,
                  :as_array => false,
                  :_id      => evidence['_id'].to_s
              )
            end
          end
        end

        def stream_evidence_array(cursor)
          stream :keep_open do |response|
            current = 0

            # determine true size of cursor given cursor limit/count
            if cursor.limit.zero?
              total = cursor.total
            else
              total = [cursor.limit, cursor.count].min
            end

            response << '['
            cursor.each do |evidence|
              evidence.delete('facets')

              response << render_resource(
                  evidence,
                  :evidence,
                  :as_array => false,
                  :_id      => evidence['_id'].to_s
              )
              current += 1
              response << ',' if current < total
            end
            response << ']'
          end
        end

        def keys_to_s_deep(hash)
          hash.inject({}) do |new_hash, (key, value)|
            kstr           = key.to_s
            if value.kind_of?(Hash)
              new_hash[kstr] = keys_to_s_deep(value)
            elsif value.kind_of?(Array)
              new_hash[kstr] = value.map do |item|
                item.kind_of?(Hash) ?
                  keys_to_s_deep(item) :
                  item
              end
            else
              new_hash[kstr] = value
            end
            new_hash
          end
        end
      end

      options '/api/evidence' do
        response.headers['Allow'] = 'OPTIONS,POST,GET'
        status 200
      end

      options '/api/evidence/:id' do
        response.headers['Allow'] = 'OPTIONS,GET,PUT,DELETE'
        status 200
      end

      post '/api/evidence' do
        # Validate JSON Evidence.
        validate_media_type! "application/json"
        evidence_obj = read_json

        schema_validation = validate_schema(keys_to_s_deep(evidence_obj), :evidence)
        unless schema_validation[0]
          halt(
            400,
            { 'Content-Type' => 'application/json' },
            render_json({ :status => 400, :msg => schema_validation[1].join("\n") })
          )
        end

        evidence = ::BEL::Model::Evidence.create(evidence_obj[:evidence])

        # Standardize annotations.
        @annotation_transform.transform_evidence!(evidence, base_url)

        # Build facets.
        facets = map_evidence_facets(evidence)
        hash = evidence.to_h
        hash[:bel_statement] = hash.fetch(:bel_statement, nil).to_s
        hash[:facets]        = facets
        _id = @api.create_evidence(hash)

        # Return Location information (201).
        status 201
        headers "Location" => "#{base_url}/api/evidence/#{_id}"
      end

			get '/api/evidence-stream', provides: 'application/json' do
        start                = (params[:start] || 0).to_i
        size                 = (params[:size]  || 0).to_i
        group_as_array       = as_bool(params[:group_as_array])

        # check filters
        filters = []
        filter_params = CGI::parse(env["QUERY_STRING"])['filter']
        filter_params.each do |filter|
          filter = read_filter(filter)
          halt 400 unless ['category', 'name', 'value'].all? { |f| filter.include? f}

          if filter['category'] == 'fts' && filter['name'] == 'search'
            halt 400 unless filter['value'].to_s.length > 1
          end

          filters << filter
        end

        cursor  = @api.find_evidence(filters, start, size, false)[:cursor]
        if group_as_array
          stream_evidence_array(cursor)
        else
          stream_evidence_objects(cursor)
        end
			end

      get '/api/evidence' do
        start                = (params[:start]  || 0).to_i
        size                 = (params[:size]   || 0).to_i
        faceted              = as_bool(params[:faceted])
        max_values_per_facet = (params[:max_values_per_facet] || -1).to_i

        # check filters
        filters = []
        filter_params = CGI::parse(env["QUERY_STRING"])['filter']
        filter_params.each do |filter|
          filter = read_filter(filter)
          halt 400 unless ['category', 'name', 'value'].all? { |f| filter.include? f}

          if filter['category'] == 'fts' && filter['name'] == 'search'
            halt 400 unless filter['value'].to_s.length > 1
          end

          filters << filter
        end

        collection_total  = @api.count_evidence()
        filtered_total    = @api.count_evidence(filters)
        page_results      = @api.find_evidence(filters, start, size, faceted, max_values_per_facet)
        evidence          = page_results[:cursor].map { |item|
          item.delete('facets')
          item
        }.to_a
        facets            = page_results[:facets]

        halt 404 if evidence.empty?

        pager = Pager.new(start, size, filtered_total)

        options = {
          :facets   => facets,
          :start    => start,
          :size     => size,
          :filters  => filter_params,
          :metadata => {
            :collection_paging => {
              :total                  => collection_total,
              :total_filtered         => pager.total_size,
              :total_pages            => pager.total_pages,
              :current_page           => pager.current_page,
              :current_page_size      => evidence.size,
            }
          }
        }

        # pager links
        options[:previous_page] = pager.previous_page
        options[:next_page]     = pager.next_page

        render_collection(evidence, :evidence, options)
      end

      get '/api/evidence/:id' do
        object_id = params[:id]
        halt 404 unless BSON::ObjectId.legal?(object_id)

        evidence = @api.find_evidence_by_id(object_id)
        halt 404 unless evidence

        evidence.delete('facets')

        # XXX Hack to return single resource wrapped as json array
        # XXX Need to better support evidence resource arrays in base.rb
        render_resource(
          evidence,
          :evidence,
          :as_array => false,
          :_id      => object_id
        )
      end

      put '/api/evidence/:id' do
        object_id = params[:id]
        halt 404 unless BSON::ObjectId.legal?(object_id)

        validate_media_type! "application/json"

        ev = @api.find_evidence_by_id(object_id)
        halt 404 unless ev

        evidence_obj = read_json
        schema_validation = validate_schema(keys_to_s_deep(evidence_obj), :evidence)
        unless schema_validation[0]
          halt(
            400,
            { 'Content-Type' => 'application/json' },
            render_json({ :status => 400, :msg => schema_validation[1].join("\n") })
          )
        end

        # transformation
        evidence          = evidence_obj[:evidence]
        evidence_model    = ::BEL::Model::Evidence.create(evidence)
        @annotation_transform.transform_evidence!(evidence_model, base_url)
        facets = map_evidence_facets(evidence_model)
        evidence = evidence_model.to_h
        evidence[:bel_statement] = evidence.fetch(:bel_statement, nil).to_s
        evidence[:facets]        = facets

        @api.update_evidence_by_id(object_id, evidence)

        status 202
      end

      delete '/api/evidence/:id' do
        object_id = params[:id]
        halt 404 unless BSON::ObjectId.legal?(object_id)

        ev = @api.find_evidence_by_id(object_id)
        halt 404 unless ev

        @api.delete_evidence_by_id(object_id)
        status 202
      end

    end
  end
end
# vim: ts=2 sw=2:
# encoding: utf-8
