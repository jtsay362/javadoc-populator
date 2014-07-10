require 'json'
require 'nokogiri'

class JavadocPopulator
  def initialize(dir_path, output_path)
    @dir_path = dir_path
    @output_path = output_path
    @first_document = true

    @modifier_and_type_regexp = /^\s*(([a-z\s]+)\s+)?(.+)$/
    @param_split_regexp = /\s*,\s*?[\r\n]+\s*/
    #@param_regexp = /\s*(.+)\s+(\w+)\s*$/
    @param_regexp = /\s*(.+?)[[:space:]]+(\w+)$/
  end

  def debug(msg)
    
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
        "kind" : {
          "type" : "string",
          "index" : "no"
        },
        "since" : {
          "index" : "no"
        },
        "description" : {
          "type" : "string",
          "index" : "analyzed"
        },
        "superClass" : {
          "index" : "no"
        },
        "implements" : {
          "index" : "no"
        },
        "name" : {
          "type" : "string",
          "index" : "not_analyzed"
        },
        "params" : {
          "index" : "no"
        },
        "throws" : {
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

        if !file_path.include?('class-use') && /([A-Z][a-z]*)+\.html/.match(simple_filename)

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
            add_class_or_interface(doc, package_name, class_name, simple_class_name, out)
            find_methods(doc, package_name, class_name, simple_class_name, out)
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

  def add_class_or_interface(doc, package_name, class_name, simple_class_name, out)
    kind = 'class'

    title = doc.css('.header h2').text()

    if title.include?('Interface')
      kind = 'interface'
    end

    description = doc.css('.description .block').text().strip.scrub

    super_class = nil

    super_class_a = doc.css('ul.inheritance li a').last

    if super_class_a
      super_class = super_class_a.text()
    end

    implements = []

    dd = doc.css('.description ul.blockList li.blockList dl dd').first

    if dd
      links = dd.css('a')

      implements = (links.collect do |a|
        title = a.attr('title')
        package = nil

        m = /.+\s+([\w\.]+)$/.match(title)

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

    since = nil

    since_label = doc.css('.description dt .simpleTagLabel').first

    if since_label
      since = since_label.parent.parent.css('dd').first.text().strip.scrub
    end

    #puts "#{class_name} description: '#{description}'"

    output_doc = {
      _id: class_name,
      package: package_name,
      class: simple_class_name,
      qualifiedClass: class_name,
      superClass: super_class,
      implements: implements,
      since: since,
      kind: kind,
      description: description,
      recognitionKeys: ['com.solveforall.recognition.java.JdkClass']
    }

    if @first_document
      @first_document = false
    else
      out.write(",\n")
    end

    out.write(output_doc.to_json)

    #puts output_doc.to_json
  end

  def find_methods(doc, package_name, class_name, simple_class_name, out)
    doc.css('.memberSummary').each do |table|
      unless table.attr('summary').include?('Method')
        next
      end

      table.css('tr').each do |tr|
        modifier_and_type = tr.css('td.colFirst').text()
        m = @modifier_and_type_regexp.match(modifier_and_type)

        unless m
          puts "Can't get modifier or return type from #{modifier_and_type}!"
          next
        end


        modifiers = []

        if m[2] && (m[2].length > 0)
          modifiers = m[2].split(/\s+/).sort
        end

        return_type = m[3]

        text = tr.css('td.colLast').text()

        m = /^\s*(\w+)\(([^)]*)\)\s*(.*?)\s*$/.match(text)

        unless m
          puts "Can't parse last column text: '#{text}'."
          next
        end

        method_name = m[1].strip.scrub
        description = m[3].strip.scrub

        params = parse_parameters(m[2])

        # if method_name == 'write'
        #   unpacked = text.unpack('H*')
        #   puts "text = '#{text}', description = '#{unpacked}'"
        #
        #
        #   0.upto(unpacked.length - 1) do |i|
        #     puts "D#{i} = '#{unpacked[i]}'"
        #   end
        #
        # end

        output_doc = {
          _id: class_name + '#' + method_name,
          package: package_name,
          class: simple_class_name,
          qualifiedClass: class_name,
          name: method_name,
          modifiers: modifiers,
          params: params,
          return_type: return_type,
          kind: 'method',
          description: description,
          recognitionKeys: ['com.solveforall.recognition.java.JdkMethod']
        }

        out.write(",\n")
        out.write(output_doc.to_json)

        #puts output_doc.to_json

      end
    end

  end

  def parse_parameters(params_text)
    params = []

    if params_text && (params_text.length > 0)
      #puts "got params text '#{params_text}'"
    else
      return
    end

    params_text.split(@param_split_regexp).each do |line|
      m = @param_regexp.match(line)
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