require_relative '../configManager'
wrapper=ConfigManager.new()


# Names of records to search for
names=["test.company.com."]

search_for=names.uniq
found=wrapper.find_record_sets(search_for)

#prints records with identical name if any and ask the user how to continue
if found.length>0
        puts "Records matching search in database::"
        puts found
        puts "\nHow do you wish to continue?\nd - delete all matching records. \nq - quit\n"
        answer=gets.chomp
        if answer=='d'
        ##### delete records #######
                puts found
                wrapper.delete_record_sets(found)
        elsif answer!='d'
                exit
        end

else
	puts "no matching records found"
end


