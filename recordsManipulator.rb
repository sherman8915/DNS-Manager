require 'rails'
require 'json'
require 'ipaddress'

$tinyDnstypeMap={
  '+' => 'A',
#  '.' => 'NS',
  'C' => 'CNAME',
#  '@' => 'MX',
}

$healthCheckRoleMap={
  :launcher => {
    :port => 443,
    :type => "TCP",
  },
  :admin =>{
    :port => 443,
    :type => "TCP",
  },
  :login => {
    :port => 443,
    :type => "TCP"
  },
  :app => {
    :port => 443,
    :type => "TCP"
  },
}

class RecordsManipulator

#Description: Generates records and converts from tiny dns to hash and from hash to JSON


  def initialize(typeMap=$tinyDnstypeMap,healthCheckRoleMap=$healthCheckRoleMap)
    @typeMap=typeMap
    @healthCheckRoleMap=healthCheckRoleMap
  end

=begin
 Input: gets a tiny dns record as input, for example: '+',' foo.company.com','53.102.59.212','one_minute'
 Output: returns a record hash of the form {:resource_records=>[{:value=>"53.102.59.212"}], :name=>"foo.company.com.", :type=>"A", :ttl=>60} 
=end  
  def parse_record(raw_record)
    record={}
    record[:type]=@typeMap[raw_record[0]]
    record[:name]=raw_record[1].gsub("\n",'').squeeze(' ')
    record[:ttl]=raw_record[3].gsub("\n",'').squeeze(' ')
    record[:resource_records]=[]
    record[:resource_records].push({:value => raw_record[2]})
    
    return record  
  end

=begin
 Input: file path for a tinydns zone files record
 Output: an array of resource record hashes 
=end
  def parse_records(filePath)
    #records={}
    records=[]
    file=File.open(filePath,"rb")
    lines=file.readlines
    lines.each do |line|
      rtype=line[0]
      if @typeMap.keys().include?(rtype)
        raw_record=[]
        raw_record=raw_record.push(rtype)+line[1..-1].split(':') # creates an array of the form [rtype,name,value,ttl]
        record=parse_record(raw_record)
        #records[record[:name]]=record
        records.push(record)
      end
    end
    file.close()
    return merge_resource_record_group(records)
  end

=begin
 Input: a hash
 Output: converts the hash into JSON format and saves JSON to file
=end
  def get_json_to_file(records,jsonFilePath)
    f=File.open(jsonFilePath,"w")    
    json=JSON.pretty_generate(records)
    f.write(json)
    f.close()    
  end

=begin
 Input: a JSON file path
 Output: return resource records hash  
=end
  def get_records_from_json(jsonFilePath)
    f=File.open(jsonFilePath,"rb")    
    json=f.read
    f.close()
    records=JSON.parse(json)
    records=symbolize_all(records)
    return records    
  end


=begin
 Input: an object
 Output: recursively symbolizes all keys within all hashes of the object 
=end
  def symbolize_all(obj)
    if obj.class==Array
      obj.collect! do |o|
        symbolize_all(o)
      end
    elsif obj.class==Hash
      obj.symbolize_keys!
      obj.each do |key,value|
        obj[key]=symbolize_all(value)
      end     
    end
    
    return obj
  end
=begin
 Input: a group of record sets with similar (type,name,ttl)
 Output: joins the values of the resource records under a single array and returns a new record set with the joined resource records
=end  
  def merge_resource_records(record_sets)
    record_sets=record_sets.uniq
    if record_sets.length>0
      new_record_set={}
      new_record_set=record_sets[0]
      new_resource_records=[]
      record_sets.each do |record_set|
        new_resource_records=new_resource_records+record_set[:resource_records]
      end
      new_record_set[:resource_records]=new_resource_records.uniq
      return new_record_set
    end

    return record_sets
  end

=begin
 Input: a group (array) of record sets
 Output: return the group of record sets with resource records merged under identical (type,name,ttl) tuples
=end  
  def merge_resource_record_group(record_sets,include_set_identifier=true)
    if record_sets.length>0
      record_sets.each do |record_set1|
        matching_records=record_sets.select {|record_set2| compare_record_sets(record_set1,record_set2,include_set_identifier)}
        if matching_records.length>1
          record_sets=record_sets.delete_if {|record_set2| compare_record_sets(record_set1,record_set2,include_set_identifier)}
          new_merged_record=merge_resource_records(matching_records)
          record_sets.push(new_merged_record)
        end
      end
      #record_sets=record_sets.uniq
    end

      return record_sets
  end

=begin
 Input: a record sets
 Output: apply special formating for record set 
=end
  def format_record_sets(record_sets)
    record_sets.collect! do |record_set|
      record_set[:ttl]=record_set[:ttl].to_i
      record_set
    end
    return record_sets
  end
  
=begin
 Input: record set, resource_records to remove from record set
 Output: returns a record set deducted from the resource records 
=end
  def remove_resource_records(record_set,resource_records)
    current_resource_records=record_set[:resource_records]
    current_resource_records=current_resource_records.delete_if {|resource_record| resource_records.include?(resource_record)}
    record_set[:resource_records]=current_resource_records
    return record_set
  end
  
=begin
 Input: an array of record_sets, an array of record sets to be excluded
 Output: returns the original record set deducting the  resource records that were excluded from the record sets
=end
  def exclude_record_sets(record_sets,exclude_set,verbose=false,set_identifier=true)
    puts "excluding record sets: #{exclude_set}" if verbose
    
    #exclude resource records from record sets
    record_sets.collect! do |record_set1|
      matching=exclude_set.select {|record_set2| compare_record_sets(record_set1,record_set2,set_identifier)}
      excluded_resource_records=[]
      matching.each {|record_set| excluded_resource_records+=record_set[:resource_records]}
      record_set1=remove_resource_records(record_set1,excluded_resource_records)
    end
    
    #delete record sets with no resource records
    record_sets=record_sets.delete_if {|record_set| record_set[:resource_records].length==0}
    return record_sets
  end


=begin
 Input: two record sets to be compared, include set identifier in the comparison
 Output: compares the "key" for the record sets, if the key is identical then these record set have the same "key" note: doesn't compare resource recourd values! 
=end  
  def compare_record_sets(record_set1,record_set2,include_set_identifier=true,include_values=false)
    baseComparison=(record_set1[:name]==record_set2[:name] and record_set1[:type]==record_set2[:type] and record_set1[:ttl]==record_set2[:ttl])
    cmp=baseComparison
    
    if include_set_identifier #also compare set ID if flag is set to true
      cmp=(cmp and record_set1[:set_identifier]==record_set2[:set_identifier])
    end
    
    if include_values==true # also compare resource record values if flag is set to true
      cmp=(cmp and record_set1[:resource_records]==record_set2[:resource_records])
    end
    
    return cmp 
  end
  
=begin
 Input: two arrays of record sets, include_set_identifier - if set to true then set identifier is also taken into account in the comparison
 Output: returns the record sets in record_set2 that has the same "key" as the record sets in record_set1 
=end
  def match_record_sets(record_sets1,record_sets2,include_set_identifier=true)
    matching_record_sets=[]
    record_sets1.each do |record_set1|
      matched=record_sets2.select {|record_set2| compare_record_sets(record_set1,record_set2,include_set_identifier)}
      matching_record_sets=matching_record_sets+matched
    end
    return matching_record_sets
  end

=begin
 Input:  two arrays of record sets, include_set_identifier - if set to true then set identifier is also taken into account in the comparison
 Output: returns an array of record sets in record_sets2 that are not matching any record set in record_sets1
=end  
  def get_non_matching_record_sets(record_sets1,record_sets2,include_set_identifier=true)
    matching_record_sets=match_record_sets(record_sets1,record_sets2,include_set_identifier)
    non_matching_record_sets=record_sets2-matching_record_sets
    
    return non_matching_record_sets
  end

=begin
 Input: the directory path from which to load the groups
 Output: loads the groups from JSON files into Hash structures
=end
  def loadGroups(groupsPath)
    groups=[]
    groupFileNames=Dir.entries(groupsPath)
    groupFileNames.each do |groupFileName|
      if (groupFileName!='.' and groupFileName!='..')
        groupFilePath=groupsPath+groupFileName
        groupName=groupFileName.sub(/\.json/,'')
        newGroup={}
        newGroup[:name]=groupName
        newGroup[:record_sets]=get_records_from_json(groupFilePath)
        groups.push(newGroup)
      end
    end
    return groups
  end

=begin
 Input: path to the directory of the json group files
 Output: saves all groups currently loaded in memroy to json 
=end
  def saveGroups(groupsPath,groups)
    groups.each do |group|
      groupFilePath=groupsPath+group[:name]+'.json'
      get_json_to_file(group[:record_sets],groupFilePath)
    end
  end

=begin
 Input: an array of record sets
 Output: if there are identical record sets, they are differentiated using a unique set ID 
=end
  def differentiate_record_sets(record_sets)
    
  end
  
=begin
 Input: array of new record sets without set ID, a master set of current record sets which all contain set ID
 Output: assigns a set ID and weight to the record set and returns it  
=end  
  def assign_set_id(record_sets,current_record_sets,hasWeight,default_weight=10)
    new_record_sets=[] # will store the new record sets after assigning a new id and a weight
    current_record_sets1=current_record_sets.clone
    record_sets.each do |record_set|
      matched_record_sets=match_record_sets([record_set],current_record_sets1,false) # matching to see for existing record sets with the same name,ttl,type currently in memory
      first_new_id=1
      if matched_record_sets.length>0
        current_ids=[] #array of current ids of existing records
        matched_record_sets.each do |matched_record_set|
          current_ids=current_ids.push(matched_record_set[:set_identifier].to_i)
        end
        first_new_id=current_ids.sort.last+1
      end
      new_id=first_new_id
      
      new_record_set=record_set
      new_record_set[:set_identifier]=new_id.to_s
      new_record_set[:weight]=default_weight if hasWeight
      new_record_sets.push(new_record_set)
      new_id=new_id+1
      current_record_sets1.push(new_record_set)
    end
    return new_record_sets
  end

=begin
 Input: a record set, port number, check type (TCP or HTTP), resource path is optional only for http
 Output: returns a health check hash object for the given record set 
=end  
  def create_healthcheck_request_record(record_set,checkType,port,resourcePath=nil,ip_address)
    randomString=createRandomString()
       healthcheck={
         :health_check_config => {
          :ip_address => ip_address,
          :port => port,
          :type => checkType,
#          :fully_qualified_domain_name => record_set[:name],
         },
         :caller_reference => randomString,
    }
    
    healthcheck[:health_check_config][:resourcePath]=resourcePath if (resourcePath!=nil and checkType=='HTTP')
    
    return healthcheck
  end

=begin
 Input:
 Output: returns a random string 
=end  
  def createRandomString()
    o =  [('a'..'z'),('A'..'Z')].map{|i| i.to_a}.flatten
    string  =  (0...50).map{ o[rand(o.length)] }.join
    return string
  end
  
=begin
 Input: record set to delete, groups - array of arrays of record sets,check_identifier - if set to true then the set ID is also compared, check_values - if set to true then resource records values are also compared 
 Output: deletes the record set from all groups 
=end  
  def delete_record_set_from_groups(record_set,groups,check_identifier=false,check_values=false)
    groups.each_with_index do |group,index|
      group[:record_sets]=group[:record_sets].delete_if {|recordSet| compare_record_sets(record_set,recordSet,check_identifier,check_values)}
      groups[index]=group
    end
    
    return groups
  end

=begin
 Input: a record set, role - a symbol designating the role of the record set 
 Output:  returns a health check request record that is tailored to the specific role
=end  
  def create_healthcheck_request_record_for_role(record_set,role,ip_address)
    type=@healthCheckRoleMap[role][:type]
    port=@healthCheckRoleMap[role][:port]
    resourcePath=@healthCheckRoleMap[role][:resourcePath]
    healthcheck=create_healthcheck_request_record(record_set,type,port,resourcePath,ip_address)
    return healthcheck
  end

=begin
 Input: record_set_groups - array of record sets groups (array of record sets), filter_parameters - hash of parameters by which to filter for the record sets: 
        {:groupNames => array of group names to filter, :names => array of record sets names to filter, :type => array of record sets types to filter}
 Output: return record sets that correspond to the filtering criteria provided from within the record_set_groups
=end  
  def filterRecordSets(record_set_groups,filter_parameters)
    matching_record_sets=[]
    all_record_sets=[]
    record_set_groups.each {|group| all_record_sets+=group[:record_sets]} #join all group record sets to a single list
    all_record_sets.uniq! # remove duplicate values from record sets
    
    filter_parameters.each_pair do |key,values|
      matching_record_sets+=all_record_sets.select {|record_set| values.include?(record_set[key])} if values.length>0
    end
    
    return matching_record_sets
  end
  
=begin
 Input: path, message
 Output: git commit and add new files in the path into git with the message provided for reference
=end 
 def commitToGit(path,message,verbose=false)
   puts "\n######   commiting changes to git  #######" if verbose
   Dir.chdir(path)
   cmd="git add ."
   puts "#{cmd}" if verbose
   exitFlagAdd=system(cmd)
   
   cmd="git commit -m \"#{message}\" -a"
   puts "#{cmd}" if verbose
   exitFlag=system(cmd)
   
   return exitFlag
 end

=begin
 Input: path - to the git repo, number - the number of revision to revert back (e.g. 1 means revert the last revision, 2 means revert the last 2 revisions...)
 Output: reverts the repo in the git path 
=end
  def rollGitRevisions()
    
  end

=begin
 Input: config file path, config hash (hash version of config file)
 Output: replaces the old config file with the new provided config hash
=end  
  def modifyConfig(configFilePath,new_config)
    newOldConfigPath=configFilePath+".old"+Time.now().inspect.gsub(' ','_')
    `cp #{configFilePath} #{newOldConfigPath}`
    get_json_to_file(new_config,configFilePath)
  end
  
=begin
 Input: record_set - the record set for which to create failover, failover_value - value for the new record set that will be used as failover can be CNAME or IP  
 Output: generates a new record a failover for the original and set original as primary and new record as secondary, returns an array with the two new records
=end    
  def create_failover_record_sets(record_set,failover_value)
    
    primary_record_set=record_set.clone()
    
    # create a new weighted CNAME record set that has the failover_value as its value and new set identifier
    secondary_record_set=record_set.clone()
    secondary_record_set[:resource_records]=[{:value=>failover_value}]
    #secondary_record_set[:resource_records][0][:value]=failover_value
    secondary_record_set[:set_identifier]=(secondary_record_set[:set_identifier].to_i()+1).to_s
    
    #if failover value provided is a valid IP address than the new secondary record set is an A record, else it's a CNAME
    if IPAddress.valid?(failover_value)
      secondary_record_set[:type]="A"
    else
      secondary_record_set[:type]="CNAME"
    end
    
    # define old record as primary and new record as seconday, remove weights
    primary_record_set[:failover]="PRIMARY"
    secondary_record_set[:failover]="SECONDARY"
    
    primary_record_set.reject! {|k| k==:weight}
    secondary_record_set.reject! {|k| k==:weight}
    
    record_sets={:primary=>primary_record_set,:secondary=>secondary_record_set}
    return record_sets
  end

=begin
 Input: record_set - a record set to find an IP for, record_sets - a pool of record sets from which to resolve the IP
 Output: the first Ip value for the record set that can be traced in the local records 
=end   
  def resolveIP(record_set,record_sets)
    if record_set[:type]=="A"
      return record_set[:resource_records][0][:value]
    else
      cname_value=record_set[:resource_records][0][:value]
      selected=record_sets.select {|record_set1| cname_value==record_set1[:name] and record_set1[:set_identifier]=="1" and (record_set1[:failover]=="PRIMARY" or record_set1[:failover]==nil)}
      
      return resolveIP(selected[0],record_sets)
    end    
  end
  
           
end


