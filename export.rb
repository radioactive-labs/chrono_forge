require "json"
require "find"

def export_files_to_json(directory, extensions, output_file, exceptions = [])
  # Convert extensions to lowercase for case-insensitive matching
  extensions = extensions.map(&:downcase)

  # Array to store file data
  files_data = []

  # Find all files in directory and subdirectories
  Find.find(directory) do |path|
    # Skip if not a file
    next unless File.file?(path)
    next if exceptions.any? { |exception| path.include?(exception) }

    # Check if file extension matches any in our list
    ext = File.extname(path).downcase[1..] # Remove the leading dot
    next unless extensions.include?(ext)

    puts path

    begin
      # Read file contents
      contents = File.read(path)

      # Add to our array
      files_data << {
        "path" => path,
        "contents" => contents
      }
    rescue => e
      puts "Error reading file #{path}: #{e.message}"
    end
  end

  # Write to JSON file
  File.write(output_file, JSON.pretty_generate(files_data))

  puts "Successfully exported #{files_data.length} files to #{output_file}"
end

# Example usage (uncomment and modify as needed):
directory = "/Users/stefan/Documents/plutonium/chrono_forge"
exceptions = ["/.github/", "/.vscode/", "gemfiles", "pkg", "node_modules"]
extensions = ["rb", "md", "yml", "yaml", "gemspec"]
output_file = "export.json"
export_files_to_json(directory, extensions, output_file, exceptions)
