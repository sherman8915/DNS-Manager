require_relative 'recordsManipulator'
require_relative 'route53Wrapper'


$configFile='/etc/custom/dnsManager/files/config.json'

class ConfigManager
  
  # Description: Manages all the logical tasks, and configuration that is interacting with record sets and dns
  # =>           Manages record sets groups logic (what groups are available to use, what to load to dns, master group, excluded records)
  # =>           Manages interaction between record sets and dns upload
  # =>           Manages pulling configuration from the config file
  # =>           Manages the interface that connects group logic with record manipulation and storage (interaction with records manupulator class) and interaction with dns (dns wrapper class)
  
  attr_accessor :groups  #stores the groups hash objects
  attr_accessor :masterRecordSets
  
  def initialize(configFile=$configFile)
    @recordsManipulator=RecordsManipulator.new()
    @configFilePath=configFile
    loadConfig(@configFilePath)
  end
  

 
=begin
 Input:
 Output: list groups that are loaded into memory 
=end
  def listGroups()
    @groups.each do |group|
      puts group[:name]
    end
  end

=begin
 Input: group name
 Output: print group record sets 
=end  
  def printGroup(name)
    grps=@groups.select {|group| group[:name]==name}
    grps.each do |grp|
      puts "\nprinting group #{grp[:name]}"
      grp[:record_sets].each do |record_set|
        puts record_set
      end      
    end 
 
  end

=begin
 Input: config file path
 Output: populate config constructs from file 
=end  
  def loadConfig(configFilePath=@configFilePath)
    @groups=[]
    @excludedRecordSets=[] #the record sets to be excluded from any upload to dns
    @masterRecordSets=[] # master list of all records available (unification of all group record sets)
    
    @config=@recordsManipulator.get_records_from_json(configFilePath)

    @groups=@recordsManipulator.loadGroups(@config[:groupsPath])
    mastergroup=(@groups.select {|group| group[:name]==@config[:masterGroupName]})[0]
    @masterRecordSets=mastergroup[:record_sets]
    excludedGroups=@groups.select {|group| @config[:excludedGroups].include?(group[:name])}
    excludedGroups.each {|group| @excludedRecordSets+=group[:record_sets]}
    @excludedRecordSets=@recordsManipulator.merge_resource_record_group(@excludedRecordSets)
    #rebuild_record_set_groups()
    @dnsWrapper=Route53wrapper.new() ##### ***** NOTE: In the future the vendor to be used within the wrapper will be defined by the config file
  end

=begin
 Input: fullSync - if set to true all record sets in dns which do not appear in the uploaded record sets are deleted, verbose -optional
 Output: loads the groups that where speciied in the config file to dns 
=end  
  def loadGroupsToDns(fullSync=false,verbose=false,commit_message="uploading to dns",groupsInDns=@config[:groupsInDns])    
    puts "\nUploading record sets to DNS" if verbose
    
    record_sets_to_upload=[]
    groupRecords=@groups.select {|group| groupsInDns.include?(group[:name])}
    groupRecords.each do |groupRecord|
      puts "scanning group #{groupRecord[:name]}" if verbose
      record_sets_to_upload+=(groupRecord[:record_sets])
    end
    record_sets_to_upload=@recordsManipulator.merge_resource_record_group(record_sets_to_upload)
    record_sets_to_upload=@recordsManipulator.exclude_record_sets(record_sets_to_upload,@excludedRecordSets,verbose)
    
    puts "Number of records to upload: #{record_sets_to_upload.length}" if verbose
    
    #uploading record sets to dns (route53)
    zone_id=@dnsWrapper.get_zone_id()
    recordsInDns=@dnsWrapper.get_resource_record_sets(zone_id) #the record sets that are currently saved in the dns server
    
    recordsToRemove=[] #records currently in dns that are not in current groups to be uploaded (will be only used if fullSync flag is set to true)
    createResponse=[]
    deleteResponse=[]
    
    begin
      
      ##### save image of the records currently in dns before the update for backup ####
      backupDnsRecordsGroup={
        :name => @config[:backupDnsGroup],
        :record_sets => recordsInDns,
      }
      @recordsManipulator.saveGroups(@config[:groupsPath],[backupDnsRecordsGroup]) 
      
      ##### check backup snapshot to git #####
      @recordsManipulator.commitToGit(@config[:dataDirectory],commit_message,verbose)
      
      
      if fullSync 
        recordsToRemove=@recordsManipulator.get_non_matching_record_sets(record_sets_to_upload,recordsInDns)
        puts "\nrecords to Remove:"
        puts recordsToRemove
        deleteResponse=@dnsWrapper.delete_resource_records(zone_id,recordsToRemove,comment="deleting non matching records from dns") if recordsToRemove.length>0
        createResponse=@dnsWrapper.create_resource_records(zone_id,record_sets_to_upload,comment="uploading records to dns")
      else
        createResponse=@dnsWrapper.create_resource_records(zone_id,record_sets_to_upload,comment="uploading records to dns")
      end
    
      responses=deleteResponse+createResponse
      return responses
    rescue
      puts "An Error has occured when trying to update dns server or when trying to store a backup of your changes. Your local record changes will be commited to git again"
      ###### check json records to git ########
      @recordsManipulator.commitToGit(@config[:dataDirectory],commit_message,verbose)
      raise
    end
    
  end
  
=begin
 Input:
 Output: rebuilds all the group files ensuring all record sets are unique with merged resource records
=end
  def rebuild_record_set_groups(commit_message="commiting changes to git",verbose=false)
    masterRecordSets=[]
    
    #make all the record sets unique in each group and generate master record set
    @groups.each_with_index do |group,index|
      if (group[:name]!=@config[:masterGroupName] and group[:name]!=@config[:backupDnsGroup])
        group[:record_sets]=group[:record_sets].uniq #ensures all record sets are uniq
        @groups[index][:record_sets]=@recordsManipulator.merge_resource_record_group(group[:record_sets]) #merges the resource records in the record set
        masterRecordSets+=group[:record_sets] #add to master record set
      end  
    end
    
    #creating new master group
    masterGroup={}
    masterGroup[:name]=@config[:masterGroupName]
    masterGroup[:record_sets]=@recordsManipulator.merge_resource_record_group(masterRecordSets)
    @masterRecordSets=masterGroup[:record_sets]
    
    #deleting old master group and placing new values in master group
    @groups=@groups.delete_if {|group| group[:name]==@config[:masterGroupName]}
    @groups=@groups.push(masterGroup)
    begin
      @recordsManipulator.saveGroups(@config[:groupsPath],@groups)
      ###### check Changes in the record into git!!! #####
      @recordsManipulator.commitToGit(@config[:dataDirectory],commit_message,verbose)
    rescue
      puts "ERROR: there may have been a problem commiting your changes"
      ###### check Changes in the record into git!!! #####
      @recordsManipulator.commitToGit(@config[:dataDirectory],commit_message,verbose)
      raise
    end
      
  end
  
=begin
 Input: array of record sets to delete, check_identifier - if set to true then the set ID is also compared, check_values - if set to true then resource records values are also compared 
 Output: deletes the record set from all groups (including master...) 
=end  
  def delete_record_sets(record_sets,check_identifier=false,check_values=false,upload_changes=false,verbose=false,groups=@groups)
    record_sets.each do |record_set|
      @groups=@recordsManipulator.delete_record_set_from_groups(record_set,groups,check_identifier,check_values)
    end
    
    #only after record deletion was commited to dns, groups can be updated and changes can be commited 
    commitMessage="deleting records"
    rebuild_record_set_groups(commitMessage,verbose)
    
    #delete record from dns
    response=loadGroupsToDns(true,verbose) if upload_changes

    return response
  end

=begin
 Input: array of group names, array of record set hashes
 Output: adds the record set to the group it to the provided group and regenerates json files
        Note: a record set has the following format: {:resource_records=>[{:value=>"118.107.167.69"}], :name=>"puppetmaster.company.com.", :type=>"A", :ttl=>60}
=end
  def add_to_groups(groupNames,record_sets,verbose=false,unique_set=true,upload_changes=false,hasWeight=true)
    new_record_sets=record_sets
    if unique_set==true #If unique set flag is true then assign a record set ID
      new_record_sets=@recordsManipulator.assign_set_id(record_sets,@masterRecordSets,hasWeight)
    end
    groupNames.each do |groupName|
      i=@groups.find_index {|group| group[:name]==groupName}
      if i!=nil
        puts "\nadding to group: #{groupName}\nThe Record sets: #{record_sets}" if verbose
        @groups[i][:record_sets]+=new_record_sets
      else
        puts "no matching group name found, creating new group: #{groupName}" if verbose
        newGroup={}
        newGroup[:name]=groupName
        newGroup[:record_sets]=new_record_sets
        @groups.push(newGroup)
      end

    end
    
    commitMessage="adding records"
    rebuild_record_set_groups(commitMessage,verbose)
 
    response=loadGroupsToDns(true,verbose) if upload_changes
  end

=begin
 Input: an array of record set
 Output: create a health check for the record set, associate it with the record set and return a new record set with the health check ID
=end  
  def create_healthcheck_for_recordset(record_set,port,checktype="TCP",resourcePath=nil)
    new_record_set=record_set.clone
    healthCheckRequest=@recordsManipulator.create_healthcheck_request_record(record_set,port,checktype,resourcePath)
    response=@dnsWrapper.create_healthcheck(healthCheckRequest)
    new_record_set[:health_check_id]=response[:id]
    
    return new_record_set
  end

=begin
 Input: an array of health chek creation tasks for record sets- each element is {:record_set => record_set, :checktype => type, resourcePath => "http://.../resource"} 
 Output: create a health check for multiple record sets, flushes the new record sets into 
=end  
  def create_healthchecks_for_recordsets(healthCheckCreationTask,verbose=false,uploadToDNS=true,commit_message="creating health check for record sets")
   # new_record_sets=[]
    healthCheckCreationTask.each do |task|
      new_record_set=create_healthcheck_for_recordset(task[:record_set],task[:checktype],task[:port],task[:resourcePath])
      update_groups(task[:record_set],new_record_set)
    end

    rebuild_record_set_groups(commit_message,verbose)
    loadGroupsToDns(false,verbose) if uploadToDNS    
  end
  
=begin
 Input: an array record sets, the record sets role
 Output: create a health check for multiple record sets, flushes the new record sets into 
=end    
 def create_healthchecks_for_role_recordsets(record_sets,role_name,verbose=false,uploadToDNS=false,commit_message="creating health check for record sets")
  healthCheckRequests=[]
  record_sets.each do |record_set|
    new_record_set=record_set.clone
    ip_address=@recordsManipulator.resolveIP(record_set,@masterRecordSets)
    healthCheckRequest=@recordsManipulator.create_healthcheck_request_record_for_role(record_set,role_name,ip_address)
    response=@dnsWrapper.create_healthcheck(healthCheckRequest)
    sleep(1) # adding some sleep time so that amazon will get enough time to process the request.
    new_record_set[:health_check_id]=response[:id]
    update_groups(record_set,new_record_set)
  end
  
  rebuild_record_set_groups(commit_message,verbose)
  loadGroupsToDns(false,verbose) if uploadToDNS
 end

=begin
 Input: old record set, new record set
 Output: updates all groups with the new record set 
=end  
  def update_groups(old_record_set,new_record_set)

    @groups.collect do |group|
      i=group[:record_sets].index {|record_set| @recordsManipulator.compare_record_sets(record_set,old_record_set)}
      group[:record_sets][i]=new_record_set if i!=nil 
    end
    
  end

=begin
 Input: filter parameters by which to filter for the record sets:  names - array of record sets names to filter, types - array of record sets types to filter, groupNames - array of group names to filter
 Output: return record sets that correspond to the filtering criteria provided
=end  
  def find_record_sets(names=[],types=[],groupNames=["masterGroup"])
 
    filter_parameters={
      :name => names,
      :type => types,
    }
    
    selected_grps=@groups.select {|group| groupNames.include?(group[:name])}
    selected_records=@recordsManipulator.filterRecordSets(selected_grps,filter_parameters)
    
    return selected_records
  end
  
=begin
 Input: config file path, config hash (hash version of config file)
 Output: creates a new config file which includes only the last snapshot from route53 as what to be included in dns, and uploads to dns
=end  
  def rollDnsToBackup(uploadToDns=false,verbose=false)
    new_config=@config.clone
    new_config[:groupsInDns]=[@config[:backupDnsGroup]]
    new_config[:excludedGroups]=[]
    @recordsManipulator.modifyConfig(@configFilePath,new_config)
    loadConfig(@configFilePath)
    loadGroupsToDns(true,verbose) if uploadToDns
  end

=begin
 Input: record_set - the record set for which to create failover, failover_value - value for the new record set that will be used as failover can be CNAME or IP  
 Output: generates a new record a failover for the original and set original as primary and new record as secondary
=end  
  def addFailover(record_set,failover_value,commit_message="generating failover",verbose=false,createHealthChecks=true,uploadToDns=false,role=:app)
    new_record_sets=@recordsManipulator.create_failover_record_sets(record_set,failover_value)
    
    #update all the groups with the changes to the primary record set
    update_groups(record_set,new_record_sets[:primary])
    
    # add secondary record set in every group where the primary record set resides
    @groups.collect do |group|
      if group[:record_sets].include?(new_record_sets[:primary])
        group[:record_sets].push(new_record_sets[:secondary])
      end
    end
    
    rebuild_record_set_groups(commit_message,verbose)
    
    if createHealthChecks
      create_healthchecks_for_role_recordsets(new_record_sets.values(),role,verbose,uploadToDns)
    end
    
  end
  
=begin
  Input: record set - array of record sets that will participate in the latency load balancing  include {name, Type, region, ttl, resource_records=>[]} like any other new recordset, just that they have region in addition
         groupNames - array of group names to be added to
         Note: load balanced records need to have the same name.
  Output: appends the new record sets to the groups (removes weight and assigns new set identifier)
=end
  def createLatencyLoadBalancing(record_sets,groupNames,roleName=:launcher,verbose=false,create_health_checks=true)
    add_to_groups(groupNames,record_sets,verbose,true,false,false)
    create_healthchecks_for_role_recordsets(record_sets,roleName)
  end

=begin
 Input: names of groups to be excluded from dns
 Output: exclude the provided groups from dns
=end
  def excludeGroups(groupNames=[])
    new_config=@config.clone
    new_config[:excludedGroups]=groupNames
    @recordsManipulator.modifyConfig(@configFilePath,new_config)
    loadConfig(@configFilePath)
  end
end
