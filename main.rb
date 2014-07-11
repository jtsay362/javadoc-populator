require 'json'
require 'set'
require 'nokogiri'

MODIFIER_AND_TYPE_REGEXP = /^[[:space:]]*(([a-z[[:space:]]]+)[[:space:]]+)?(.+)$/
PARAM_SPLIT_REGEXP = /[[:space:]]*,[[:space:]]*?[\r\n]+[[:space:]]*/
PARAM_REGEXP = /[[:space:]]*(.+?)[[:space:]]+(\w+)$/

ABBREVIATED_MEMBER_KEYS = [:name, :params, :returnType, :modifiers, :description, :kind].to_set

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
        "package" : {
          "type" : "string",
          "index" : "not_analyzed"
        },
        "class" : {
          "type" : "string",
          "index" : "not_analyzed"
        },
        "qualifiedClass" : {
          "type" : "string",
          "index" : "not_analyzed"
        },
        "modifiers" : {
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
          "index" : "not_analyzed"
        },
        "qualifiedName" : {
          "type" : "string",
          "index" : "not_analyzed"
        },
        "superClass" : {
          "index" : "no"
        },
        "implements" : {
          "index" : "no"
        },
        "methods" : {
          "index" : "no"
        },
        "params" : {
          "index" : "no"
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
           /([A-Z][a-z]*)+\.html/.match(simple_filename)

          abs_file_path = File.expand_path(file_path)

          class_name = abs_file_path[abs_dir_path.length, abs_file_path.length - abs_dir_path.length]

          if class_name.start_with?(File::SEPARATOR)
            class_name = class_name[File::SEPARATOR.length, class_name.length - File::SEPARATOR.length]
          end

          class_name = class_name[0, class_name.length - 5]
          class_name = class_name.gsub('/', '.')

          package_name = ''
          simple_class_name = class_name

          last_dot_index = class_name.rindex('.')

          if last_dot_index >= 0
            package_name = class_name[0, last_dot_index]
            simple_class_name = class_name[last_dot_index + 1, class_name.length - last_dot_index - 1]
          end

          puts "Opening file '#{file_path}' for class '#{class_name}' ..."

          File.open(file_path) do |f|
            doc = Nokogiri::HTML(f)
            methods = find_methods(doc, package_name, class_name, simple_class_name, out)
            add_class_or_interface(doc, package_name, class_name, simple_class_name, methods, out)
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

  def add_class_or_interface(doc, package_name, class_name, simple_class_name, methods, out)
    kind = 'class'

    title = doc.css('.header h2').text().strip

    if title.start_with?('Interface')
      kind = 'interface'
    elsif title.start_with?('Enum')
      kind = 'enum'
    elsif title.start_with?('Annotation')
      kind = 'annotation'
    end

    modifiers_text = doc.css('.description ul.blockList li.blockList pre').text()

    stop_marker = kind
    if kind == 'annotation'
      stop_marker = '@'
    end

    modifiers_text = modifiers_text.slice(0, modifiers_text.index(stop_marker)).strip
    modifiers = (modifiers_text.split(PARAM_SPLIT_REGEXP) || []).sort

    description = truncate(doc.css('.description .block').text())

    super_class = nil

    if kind == 'class'
      super_class_a = doc.css('ul.inheritance li a').last

      if super_class_a
        super_class = super_class_a.text().strip
      end

      if !super_class && (kind != 'interface')
        super_class = 'java.lang.Object'
      end
    end

    if kind != 'annotation'
      implements = []

      dd = nil

      if kind == 'interface'
        dt = doc.css('.description ul.blockList li.blockList dl dt').find do |dt|
          dt.text.include?('Superinterface')
        end

        if dt
          dd = dt.parent.css('dd').first
        end
      else
        dd = doc.css('.description ul.blockList li.blockList dl dd').first
      end

      # Messes up for Comparable<Date>
      if dd
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
      package: package_name,
      class: simple_class_name,
      qualifiedClass: class_name,
      name: simple_class_name,
      qualifiedName: class_name,
      modifiers: modifiers,
      since: since,
      kind: kind,
      description: description,
      recognitionKeys: ['com.solveforall.recognition.programming.java.JdkClass']
    }

    if kind == 'class'
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

    member[:description] = truncate(member[:description], 80)

    return member
  end

  def find_methods(doc, package_name, class_name, simple_class_name, out)
    debug("find_methods for #{class_name}")

    methods = []

    # memberSummary is for JDK 8
    # overviewSummary is for JDK 7
    doc.css('.memberSummary, .overviewSummary').each do |table|
      unless table.attr('summary').include?('Method')
        debug("no methods for #{class_name}")
        next
      end

      table.css('tr').each do |tr|
        modifier_and_type = tr.css('td.colFirst').text()
        m = MODIFIER_AND_TYPE_REGEXP.match(modifier_and_type)

        if !m
          debug("can't match modifier and type for #{class_name}")
          next
        end

        modifiers = []

        if m[2] && (m[2].length > 0)
          modifiers = m[2].split(/[[:space:]]+/).sort
        end

        return_type = m[3]

        text = tr.css('td.colLast').text()

        m = /^\s*(\w+)\(([^)]*)\)\s*(.*?)\s*$/.match(text)

        unless m
          puts "Can't parse last column text: '#{text}'."
          next
        end

        method_name = m[1].strip.scrub
        description = truncate(m[3])

        params = parse_parameters(m[2])

        output_doc = {
          package: package_name,
          class: simple_class_name,
          qualifiedClass: class_name,
          name: method_name,
          qualifiedName: class_name + '.' + method_name,
          modifiers: modifiers,
          params: params,
          returnType: return_type,
          kind: 'method',
          description: description,
          recognitionKeys: ['com.solveforall.recognition.programming.java.JdkMethod']
        }

        out.write(",\n")
        out.write(output_doc.to_json)

        #puts output_doc.to_json

        debug(output_doc.to_json)

        methods << abbreviate_member(output_doc)
      end
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
end

output_filename = 'jdk8-doc.json'

if ARGV.length > 1
  output_filename = ARGV[1]
end

JavadocPopulator.new(ARGV[0], output_filename).populate