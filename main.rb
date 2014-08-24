require 'json'
require 'set'
require 'nokogiri'

ANNOTATIONS_REGEXP = /(?:@[\w\.]+(?:\([^)]*\))?[[:space:]])*/
METHOD_SIGNATURE_REGEXP = /^((?:@[\w\.]+(?:\([^)]*\))?[[:space:]])*)((?:public|protected|private|abstract|static|final)[[:space:]]+)*([^(]+?)[[:space:]]+(\w+)[[:space:]]*\(([^)]*)\)[[:space:]]*(?:throws[[:space:]]+(.+))?/
SPACES_REGEXP = /[[:space:]]+/
LINE_BREAK_REGEXP = /[[:space:]]*[\r\n]+[[:space:]]*/
PARAM_SPLIT_REGEXP = /[[:space:]]*,[[:space:]]*?[\r\n]+[[:space:]]*/
PARAM_REGEXP = /[[:space:]]*(.+?)[[:space:]]+(\w+)$/

ABBREVIATED_MEMBER_KEYS = [:name, :params, :returnType, :modifiers, :description, :path].to_set

class JavadocPopulator
  def initialize(dir_path, output_path, debug_mode=false)
    @dir_path = dir_path
    @output_path = output_path
    @first_document = true
    @debug_mode = debug_mode

    #PARAM_REGEXP = /\s*(.+)\s+(\w+)\s*$/
  end

  def debug(msg)
    if @debug_mode
      puts msg
    end
  end
  
  def populate
    puts "Populating from '#{@dir_path}' to #{@output_path}' ..."

    first_document = true

    File.open(@output_path, 'w:UTF-8') do |out|
      out.write <<-eos
{
  "metadata" : {
    "mapping" : {
      "_all" : {
        "enabled" : false
      },
      "properties" : {
        "class" : {
          "type" : "string",
          "index" : "analyzed",
          "analyzer" : "simple"
        },
        "qualifiedClass" : {
          "type" : "string",
          "index" : "analyzed",
          "analyzer" : "simple"
        },
        "annotations" : {
          "type" : "object",
          "enabled" : false
        },
        "modifiers" : {
          "type" : "string",
          "index" : "no"
        },
        "kind" : {
          "type" : "string",
          "index" : "no"
        },
        "since" : {
          "type" : "string",
          "index" : "no"
        },
        "description" : {
          "type" : "string",
          "index" : "analyzed"
        },
        "name" : {
          "type" : "string",
          "index" : "analyzed",
          "analyzer" : "simple"
        },
        "qualifiedName" : {
          "type" : "string",
          "index" : "analyzed",
          "analyzer" : "simple"
        },
        "path" : {
          "type" : "string",
          "index" : "no"
        },
        "recognitionKeys" : {
          "type" : "string",
          "index" : "no"
        },
        "superClass" : {
          "type" : "string",
          "index" : "no"
        },
        "implements" : {
          "type" : "string",
          "index" : "no"
        },
        "methods" : {
          "type" : "object",
          "enabled" : false
        },
        "params" : {
          "type" : "object",
          "enabled" : false
        },
        "returnType" : {
          "type" : "string",
          "index" : "no"
        },
        "returns" : {
          "type" : "string",
          "index" : "no"
        },
        "throws" : {
          "type" : "string",
          "index" : "no"
        },
        "packageBoost" : {
          "type" : "float",
          "store" : true,
          "null_value" : 1.0,
          "coerce" : false
        }
      }
    }
  },
  "updates" : [
      eos

      abs_dir_path = File.expand_path(@dir_path)

      num_classes_found = 0
      Dir["#{@dir_path}/**/*.html"].each do |file_path|

        simple_filename = File.basename(file_path)

        if !file_path.include?('class-use') && !file_path.include?('doc-files') &&
           /([A-Z][a-z]*\.)*([A-Z][a-z]*)\.html/.match(simple_filename)

          abs_file_path = File.expand_path(file_path)

          class_name = abs_file_path.slice(abs_dir_path.length, abs_file_path.length - abs_dir_path.length)

          if class_name.start_with?(File::SEPARATOR)
            class_name = class_name.slice(File::SEPARATOR.length, class_name.length - File::SEPARATOR.length)
          end

          class_name = class_name.slice(0, class_name.length - 5).gsub('/', '.')

           # unless class_name == 'java.util.LinkedList'
           #   next
           # end

          simple_class_name = simple_filename.slice(0, simple_filename.length - 5)

          puts "Opening file '#{file_path}' for class '#{class_name}' ..."

          File.open(file_path) do |f|
            doc = Nokogiri::HTML(f)

            package_name = doc.css('.header .subTitle').text()

            methods = find_methods(doc, package_name, class_name, simple_class_name, out)
            add_class(doc, package_name, class_name, simple_class_name, methods, out)
            num_classes_found += 1

            # if num_classes_found > 10
            #   out.write("\n  ]\n}")
            #   return
            # end
          end
        end
      end

      out.write("\n  ]\n}")

      puts "Found #{num_classes_found} classes."
    end
  end

  private

  def truncate(s, size=500)
    unless s
      return nil
    end

    pre_ellipsis_size = size - 3
    s = s.strip.scrub

    if s && (s.length > pre_ellipsis_size)
      return s.slice(0, pre_ellipsis_size) + '...'
    end

    return s
  end

  def make_class_path(package_name, simple_class_name)
    return package_name.gsub(/\./, '/') + '/' + simple_class_name + '.html'
  end

  def add_class(doc, package_name, class_name, simple_class_name, methods, out)
    kind = 'class'

    title = doc.css('.header h2').text().strip

    if title.start_with?('Interface')
      kind = 'interface'
    elsif title.start_with?('Enum')
      kind = 'enum'
    elsif title.start_with?('Annotation')
      kind = 'annotation'
    end

    annotations = []

    pre_element = doc.css('.description ul.blockList li.blockList>pre').first
    pre_text = pre_element.text().strip
    modifiers_text = pre_text

    m = ANNOTATIONS_REGEXP.match(pre_text)

    if m
      annotations = m[0].split(LINE_BREAK_REGEXP)
      modifiers_text = pre_text.slice(m[0].length .. -1)
    end

    stop_marker = kind
    if kind == 'annotation'
      stop_marker = '@'
    end

    modifiers_text = modifiers_text.slice(0, modifiers_text.index(stop_marker)).strip
    modifiers = (modifiers_text.split(SPACES_REGEXP) || []).sort

    description_block = pre_element.next_element

    description = nil
    if description_block && (description_block.attr('class') == 'block')
      description = truncate(description_block.text())
    end

    super_class = nil
    implements = []

    if kind != 'annotation'
      if kind == 'class'
        super_class_a = doc.css('ul.inheritance li a').last

        if super_class_a
          super_class = super_class_a.text().strip
        end

        if !super_class
          super_class = 'java.lang.Object'
        end
      elsif kind == 'enum'
        super_class = 'java.lang.Enum'
      end

      dt = nil

      if kind == 'interface'
        dt = doc.css('.description ul.blockList li.blockList dl dt').find do |dt|
          dt.text.downcase.include?('superinterface')
        end
      else
        dt = doc.css('.description ul.blockList li.blockList dl dt').find do |dt|
          text = dt.text.downcase
          text.include?('implemented') && text.include?('interface')
        end
      end

      # Messes up for Comparable<Date>
      if dt
        dd = dt.parent.css('dd').first
        links = dd.css('a')

        implements = (links.collect do |a|
          title = a.attr('title')
          package = nil

          m = /.+[[:space:]]+([\w\.]+)$/.match(title)

          if m
            package = m[1].strip.scrub
          end

          simple = a.text().strip.scrub

          if package
            package + '.' + simple
          else
            simple
          end
        end).sort
      end
    end

    since = nil

    since_label = doc.css('.description dt').find do |node|
      node.text().include?("Since:")
    end

    if since_label
      since = since_label.parent.css('dd').first.text().strip.scrub
    end

    #puts "#{class_name} description: '#{description}'"

    output_doc = {
      _id: class_name,
      class: simple_class_name,
      qualifiedClass: class_name,
      name: simple_class_name,
      qualifiedName: class_name,
      annotations: annotations,
      modifiers: modifiers,
      since: since,
      kind: kind,
      description: description,
      path: make_class_path(package_name, simple_class_name),
      packageBoost: package_boost(package_name),
      recognitionKeys: ['com.solveforall.recognition.programming.java.JdkClass'],
    }

    if (kind == 'class') || (kind == 'enum')
      output_doc[:superClass] = super_class
      output_doc[:methods] = methods
      output_doc[:implements] = implements
    elsif kind == 'interface'
      output_doc[:methods] = methods
      output_doc[:implements] = implements
    end

    if @first_document
      @first_document = false
    else
      out.write(",\n")
    end

    out.write(output_doc.to_json)

    #puts output_doc.to_json
  end

  def abbreviate_member(member)
    member = member.select do |k, v|
      ABBREVIATED_MEMBER_KEYS.include?(k)
    end

    member[:description] = truncate(member[:description], 250)
    member[:params].each do |param|
      param.delete(:description)
    end

    return member
  end

  def find_methods(doc, package_name, class_name, simple_class_name, out)
    debug("find_methods for #{class_name}")

    methods = []

    method_detail_anchor = doc.css('.details h3').find do |element|
      element.text().strip.downcase.include?('method detail')
    end

    if method_detail_anchor.nil?
      return []
    end

    list_items = method_detail_anchor.parent.css('ul.blockList>li')

    list_items.each do |item|

      #puts "item = #{item}"

      anchor_path = item.parent.previous_element.attr('name') || ''

      path = make_class_path(package_name, simple_class_name) + '#' + anchor_path

      signature = item.css('pre').first.text().strip

      m = METHOD_SIGNATURE_REGEXP.match(signature)

      unless m
        debug("Can't match signature '#{signature}'")
        next
      end

      annotations = (m[1] || '').strip.split(LINE_BREAK_REGEXP)
      modifiers = (m[2] || '').strip.split(SPACES_REGEXP).sort
      return_type = m[3]
      method_name = m[4]
      params = parse_parameters(m[5])
      throws_text = m[6]

      throws = []
      if throws_text
        throws = throws_text.strip.split(/[[:space:]],[[:space:]]/)
      end

      debug("path = '#{path}', annotations = #{annotations}, modifiers = #{modifiers}, return_type = '#{return_type}', name = '#{method_name}', params = #{params}, throws = #{throws}")

      description = nil
      description_block = item.css('.block').first

      if description_block
        description = truncate(description_block.text().strip)
      end

      parameters_label = item.css('dt').find do |dt|
        dt.text().downcase.include?('parameters:')
      end

      if parameters_label
        dd = parameters_label.next_element

        while dd && (dd.name == 'dd') do
          m = /(\w+)[[:space:]]+(?:\-[[:space:]])*(.+)/.match(dd.text().strip)

          if m
            param_name = m[1]
            param_description = m[2]
            param = params.find do |p|
              p[:name] == param_name
            end

            if param
              param[:description] = truncate(param_description, 250)
            end
          end

          dd = dd.next_element
        end
      end

      returns_label = item.css('dt').find do |dt|
        dt.text().downcase.include?('returns:')
      end

      returns_description = nil
      if returns_label
        returns_description = returns_label.next_element.text().strip
      end

      output_doc = {
        class: simple_class_name,
        qualifiedClass: class_name,
        name: method_name,
        qualifiedName: class_name + '.' + method_name,
        annotations: annotations,
        modifiers: modifiers,
        path: path,
        params: params,
        returnType: return_type,
        returns: returns_description,
        throws: throws,
        kind: 'method',
        description: description,
        packageBoost: package_boost(package_name),
        recognitionKeys: ['com.solveforall.recognition.programming.java.JdkMethod']
      }

      if @first_document
        @first_document = false
      else
        out.write(",\n")
      end

      output_json = output_doc.to_json
      out.write(output_json)

      debug(output_json)

      methods << abbreviate_member(output_doc)
    end

    debug("done find_methods for #{class_name}")

    return methods
  end

  def parse_parameters(params_text)
    params = []

    if params_text && (params_text.length > 0)
      #puts "got params text '#{params_text}'"
    else
      return params
    end

    params_text.split(PARAM_SPLIT_REGEXP).each do |line|
      m = PARAM_REGEXP.match(line)
      if m
        param = {
            type: m[1],
            name: m[2]
        }
        params << param
      else
        puts "Unmatched param line: '#{line}'!"
      end
    end

    params
  end

  def package_boost(package_name)
    if package_name.start_with?('java.awt')
      return 0.7
    elsif package_name.start_with?('java.sql')
      return 0.9 # because java.sql.Date conflicts with java.util.Date
    elsif package_name.start_with?('java.') || package_name.start_with?('javax.')
      return 1.0
    else
      return 0.8
    end
  end
end

output_filename = 'jdk7-doc.json'

if ARGV.length > 1
  output_filename = ARGV[1]
end

JavadocPopulator.new(ARGV[0], output_filename).populate
system("bzip2 -kf #{output_filename}")