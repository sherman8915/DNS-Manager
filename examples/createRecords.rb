require_relative '../configManager'
wrapper=ConfigManager.new()



##### put new records below in the new_record_sets array:
record_sets=[
  {:type=>"CNAME", :name=>"name1.company.com.",:ttl=>60, :resource_records=>[{:value=>"name2.company.com."}]},
  {:type=>"A", :name=>"name2.company.com.",:ttl=>60, :resource_records=>[{:value=>"104.212.201.144"}]},
]

#include the groups you wish to add in this array
#groups=["prod"] # the groups into which you wish to add the records
groups=["prod"] 





#Search first to check for any existing records with the same name
names=[]
record_sets.each do |record_set|
        names.push(record_set[:name])
end

search_for=names.uniq
found=wrapper.find_record_sets(search_for)

#prints records with identical name if any and ask the user how to continue
if found.length>0
        puts "Records found with the same name already in the database::"
        puts found
        puts "\nHow do you wish to continue?\nc - Continue:  Add additional records and leave existing records in place.\nd - delete all DNS records matching the new records (including all types of records) and add the new records.  This is sort of the equivalent of overwrite which is probably what you want to do in most cases. \nq - quit\n"
        answer=gets.chomp
        if answer=='d'
        ##### delete records #######
                puts found
                wrapper.delete_record_sets(found)
        elsif answer!='c'
                exit
        end
end

#this method adds the new records to the groups you specified within the local json storage and commits your changes
wrapper.add_to_groups(groups,record_sets,true,true)

#shows you the records that you added an asks you if you wish to upload
found=wrapper.find_record_sets(search_for)
if found.length>0
        puts "Records added:"
        puts found
        puts "\Upload Records(y/n)?"
        answer=gets.chomp
        if answer=='y'
        ##### upload records #######
                response=wrapper.loadGroupsToDns(true,true)
                puts response
        end
else
        puts "No records found please make sure these where added correctly"
end

