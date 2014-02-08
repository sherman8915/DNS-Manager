require 'rails'
require 'aws-sdk'
require 'yaml'
require_relative 'recordsManipulator'  

class Route53wrapper
  attr_accessor :r53
=begin
 Input: config file path
 Output: instantiates a route53 wrapper with the authorization and configuration in the config file path
=end
  def initialize(config_file_path='/etc/custom/liveops.yaml')
    get_aws_auth_config(config_file_path)
    @r53=AWS::Route53.new
    @recordsManipulator=RecordsManipulator.new()
  end

=begin
 Input: path to a YAML file with AWS authentication configurations
 Output: instantiates the session with AWS 
=end   
  def get_aws_auth_config(config_file_path)
    puts "\nloading config #{config_file_path}"
    config = YAML.load(File.read(config_file_path))
    AWS.config(config)
  end

=begin
 Input:
 Output: return the first zone id 
=end
  def get_zone_id()
    r53 = @r53
    zones=r53.client.list_hosted_zones
    ids=[]
    zones[:hosted_zones].each do |zone|
      ids<<zone[:id]
    end
    return ids[0]
  end

=begin
  Input: zone id
  Output: returns the zone RR set 
=end
  def get_resource_record_sets(zone_id,max_items=100)
      r53 = @r53
      
      record_sets=[]
      response=r53.client.list_resource_record_sets({:hosted_zone_id => zone_id})
      new_record_sets=response[:resource_record_sets]
      record_sets+=new_record_sets
      
      while new_record_sets.length>0
        lastRecordName=new_record_sets.last()[:name]
        response=r53.client.list_resource_record_sets({:hosted_zone_id => zone_id, :start_record_name => lastRecordName})
        new_record_sets=response[:resource_record_sets]
        new_record_sets.shift
        record_sets+=new_record_sets
      end
      
      # correcting amazon crapy format when using astersisks (*)
      record_sets.collect do |record_set|
        record_set[:name].sub!("\\052","*")
      end
      
      return record_sets
      
  end
  
=begin
 Input: zone id, array of resource records to delete, array of resource records to create, verbose flag, override delete - if records does not exist it will not try and delete them, override create - if record exists delete old record and recreate them 
 Output: delete the provided resource records and then create the provided resource records to create
=end
  def update_resource_records(zone_id,delete_resource_record_sets=[],create_resource_record_sets=[],comment="No comment",verbose=false,override_delete=true,override_create=false)

    
    if override_delete==true
        matching=match_zone_record_sets(zone_id,delete_resource_record_sets)
        delete_resource_record_sets=matching
    end
 
    
    if override_create==true
      matching=match_zone_record_sets(zone_id,create_resource_record_sets)
      delete_resource_record_sets = (delete_resource_record_sets + matching).uniq
    end
    
    puts "Records to be deleted:\n #{delete_resource_record_sets}" if verbose
    puts "Records to be created:\n #{create_resource_record_sets}" if verbose

    batch=generate_resource_update_batch(zone_id,delete_resource_record_sets,create_resource_record_sets,comment)
    puts "\nBatch Generated:\n#{batch}" if verbose
    r53=@r53
    response=r53.client.change_resource_record_sets(batch)
    
    return response
  end
  
  
=begin
 Input: zone id, array of resource records to create, comment, verbose flag, size of the chunk to send each time
 Output: creates new resource records and return response
=end
  def create_resource_records(zone_id,create_resource_record_sets,comment="create resource records",verbose=false,chunk_size=50)
    responses=[]
    create_resource_record_sets.each_slice(chunk_size) do |record_set_slice|
      response=update_resource_records(zone_id,[],record_set_slice,comment,verbose,true,true)
      responses.push(response)
    end
    return responses
  end

=begin
 Input: zone id, array of resource records to delete, comment, verbose flag, size of the chunk to send each time
 Output: delete resource records and return response
=end
  def delete_resource_records(zone_id,delete_resource_record_sets,comment="delete resource records",verbose=false,chunk_size=50)   
    responses=[]
    delete_resource_record_sets.each_slice(chunk_size) do |record_set_slice|
      response=update_resource_records(zone_id,record_set_slice,[],comment,verbose,true,true)
      responses.push(response)
    end
    return responses
      
  end
  
  
=begin
 Input: zone id, array of resource records to delete, array of resource records to create, verbose flag, override delete - if records does not exist it will not try and delete them, override create - if record exists delete existing and recreate them 
 Output: delete the provided resource records and then create the provided resource records to create - this action is not atomic and will be performed in chuncks
=end
  def update_resource_records_in_chuncks(zone_id,delete_resource_record_sets=[],create_resource_record_sets=[],comment="No comment",verbose=false,override_delete=true,override_create=false,chunck=50)
    
    delete_resource_record_sets.
    
    return response
  end
=begin
 Input: zone id, array of resource records to delete, array of resource records to create
 Output: generate a batch request that will delete the provided resource records and then create the provided resource records to create 
=end
  def generate_resource_update_batch(zone_id,delete_resource_record_sets,create_resource_record_sets,comment)
    batch={}
    batch[:hosted_zone_id]=zone_id
    batch[:change_batch]={}
    batch[:change_batch][:comment]=comment
    batch[:change_batch][:changes]=[]
    
    delete_resource_record_sets.each do |record_set|
      change={
        :action => 'DELETE',
        :resource_record_set => record_set
      }
      batch[:change_batch][:changes] << change
    end
    
    create_resource_record_sets.each do |record_set|
      change={
        :action => 'CREATE',
        :resource_record_set => record_set
      }
      batch[:change_batch][:changes] << change
    end
    
    return batch
  end
  
=begin
 Input: zone id, an array of resource records
 Output: returns matching records between the provided resource records to records within the zone id
=end
  def match_zone_record_sets(zone_id,record_sets,verbose=false)
    zone_record_sets=get_resource_record_sets(zone_id)
    puts "current record sets:\n #{record_sets}" if verbose
    manipulator=RecordsManipulator.new()
    matching_records=manipulator.match_record_sets(record_sets,zone_record_sets)
    
    return matching_records
  end
  
  def get_changes_status()
    
  end  

=begin
 Input: a health check request object , flag for always creating new health check
 Output: create a health check returns health check ID, if alwaysNew flag is set to false than the method will first check for identical existing health checks with the same parameters and will return their ID instead (default behaviour)
=end  
  def create_healthcheck(healthCheckRequest,alwaysNew=false)
    
    response={}
    if alwaysNew
      response=@r53.client.create_health_check(healthCheckRequest)
    else # if healthcheck with similar config already exists, then return the first matching health check
      currentHealthChecks=get_healthchecks()
      matched=currentHealthChecks.select {|healthCheck| healthCheck[:health_check_config]==healthCheckRequest[:health_check_config]}
      if matched.length >0
        response=matched[0]
      else
        response=@r53.client.create_health_check(healthCheckRequest)
      end     
    end
    
    return response
  end

=begin
  Input:
  Output: returns an array of health checks
=end
  def get_healthchecks()
    response=@r53.client.list_health_checks()
    return response[:health_checks]
  end

  
=begin
 Input:
 Output: 
=end  
  def delete_healthcheck_for_recordset(record_set)
    
  end

end


