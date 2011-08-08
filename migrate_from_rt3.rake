# RedMine - project management software
# Copyright (C) 2006-2007  Jean-Philippe Lang
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# 
# You should have received a copy of the MIT
# along with this program; if not, assume this file
# follows the MIT license.
#
# RT3 migration by James Rowe Copyright (C) 2010
#
# Author::    James Rowe  (mailto:james.s.rowe@google.com)
# Copyright:: Copyright (c) 2010
# License::   Distributes under the MIT license


# TODO: 
# => RT custom fields besides text and list
# => priority normilization ie 1-10 integers convert to Low, Normal, High, Urgent
# => more advanced user migrate
#     * Admin Users
#     * Groups
#     * better Name => fname lname mapping, or prompt
#     * Transfer issues with 'watched' turned on if user is watching it
#     * Role mapping from RT to Redmine
# => counts don't make much sense at the end. verify
# => time tracking is not ideal. if time worked set from 0 to 30, then 30 to 50, 80 min are migrated
# => parsing html stored values, or just look for plain/text content
# => use RedCloth for html to textile instead of html2textile

# includes
require 'active_record' # db access
require 'iconv' # setting char sets
require 'pp'
require 'tempfile'

# convert html to textile
if Gem.available?('html2textile') then require 'html2textile' end

namespace :redmine do
  desc "Migrate from RT3 to Redmine"
  task :migrate_from_rt3  => :environment do
    
    # RTMigrate module will map RT objects to Redmine objects
    module RTMigrate
      
      # set up the mappings from RT -> redmine
      # RT does not have by default a tracker. all tickets are
      # "categorized" by queue, status, and priority
      TICKET_MAP = []
      
      RELATION_TYPE_MAPPING = {
                'MergedInto' => IssueRelation::TYPE_DUPLICATES, # duplicate of
                'RefersTo' => IssueRelation::TYPE_RELATES,    # related to
                'DependsOn' => IssueRelation::TYPE_BLOCKS,    # blocker
              }

      DEFAULT_STATUS = IssueStatus.default
      assigned_status = IssueStatus.find_by_position(2)
      resolved_status = IssueStatus.find_by_position(3)
      feedback_status = IssueStatus.find_by_position(4)
      closed_status = IssueStatus.find :first, :conditions => { :is_closed => true }
      rejected_status = IssueStatus.find :last, :conditions => { :is_closed => true }
      STATUS_MAPPING = {'new' => DEFAULT_STATUS,
                        'open' => assigned_status,
                        'stalled' => feedback_status,
                        'resolved' => closed_status,
                        'rejected' => rejected_status,
                        'deleted' => rejected_status # should get skipped over, but here if that code gets removed (ie migrate deleted tickets)
                        }
      
      
      PRIORITY_MAPPING = IssuePriority.all
      DEFAULT_PRIORITY = PRIORITY_MAPPING[0]
      
      # RT3 Doesn't natively have a concept of tracker. Our organziation had a custom
      # field called "Ticket Type" which maps to Tracker
      TRACKER_BUG = Tracker.find_by_position(1)
      TRACKER_FEATURE = Tracker.find_by_position(2)
      TRACKER_SUPPORT = Tracker.find_by_position(3)
      # default going with "Support" because RT is originally a support based system
      DEFAULT_TRACKER = TRACKER_SUPPORT
      TRACKER_MAPPING = {'Bug' => TRACKER_BUG,
                         'Error' => TRACKER_BUG,
                         'Feature Request' => TRACKER_FEATURE
                         }

      roles = Role.find(:all, :conditions => {:builtin => 0}, :order => 'position ASC')
      manager_role = roles[0]
      developer_role = roles[1]
      reporter_role = roles[2]
      DEFAULT_ROLE = roles.last
      ROLE_MAPPING = {'admin' => manager_role,
                      'developer' => developer_role,
                      'reporter' => reporter_role
                      }
      
      # TODO target all RT custom field types
      # MAP RT Custom fields to Redmine custom fields
      CUSTOM_FIELD_MAPPING = { 'Select' => 'list'
                              }
      CUSTOM_FIELD_MAPPING.default = 'string' # if not found default to string type
      
      # utillity class used to take time in the past
      class ::Time
        class << self
          alias :real_now :now
          def now
            real_now - @fake_diff.to_i
          end
          def fake(time)
            @fake_diff = real_now - time
            res = yield
            @fake_diff = 0
           res
          end
        end
      end
      
      # Basic wiki syntax conversion, an RT ticket comment = Redmine issue update
      def self.convert_wiki_text(text, contenttype, contentencoding)
        return '' if text.blank? # nothing to convert
        
        text = text.strip
        if contentencoding == "quoted-printable"
          # doesn't deal with =A0 (&nbsp;) correctly, so remove it
          text = text.gsub(/=A0/, ' ').unpack('M*').to_s
        end
        # if we have the gem lets translate html to textile
        if Gem.available?('html2textile') # we've included it above
          if contenttype == "text/html" # only parse html blocks
            # remove RT generated <img> tags, they are useless, don't translate, and we add it back later
            text = text.downcase.gsub(/<\/?img[^>]*>/, '')
            
            # plain text blocks include a link to an issue with <URL link > so any more than one is considered 'html'
            # because not all stored blocks of html have <html> tags
            parser = HTMLToTextileParser.new
            parser.feed(text)
            text = parser.to_textile
          end
        else
          # escape html code
          text = ERB::Util.html_escape(text)
        end
        
        text
      end # end convert_wiki_text def
      
      # entry point for migrate script.
      def self.migrate
        establish_connection
        
        # quick DB test
        RTUsers.count # fails out if not connected properly
        
        # what are we migrating
        migrated_custom_values = 0
        migrated_tickets = 0
        attempted_migrated_ticket_attachments = 0
        migrated_ticket_attachments = 0
        
        puts 'migrating data'
        # lets do a transaction
        ActiveRecord::Base.transaction do
          
          # Plan of action (users added as-needed basis)
          # == transfer the basic stuff
          # * custom fields
          # ** available values
          # * Queues (map to projects)
          # ** Tickets (map to issues)
          # *** Convert transactions to messages
          # *** Extract attatchments to file system
          # *** RT links => Redmine issue_relations
          
          # Custom fields
          print "Migrating custom fields"
          custom_field_map = {}
          RTCustomFields.find_each do |field|
            print '.'
            STDOUT.flush
            # Redmine custom field name
            field_name = encode(field.Name[0, limit_for(IssueCustomField, 'name')]).humanize
            # Find if the custom already exists in Redmine
            f = IssueCustomField.find_by_name(field_name)
            # Or create a new one
            field_format = CUSTOM_FIELD_MAPPING[field.Type]
            
            f ||= IssueCustomField.create(:name => encode(field.Name[0, limit_for(IssueCustomField, 'name')]).humanize,
                                          :field_format => encode(field_format))
            
            # get possible values if list based
            if f.field_format.downcase == 'list'
              field.customfieldvalues.find_each do |field_value|
                f.possible_values = (f.possible_values + field_value.Name.scan(/^.*/)).flatten.compact.uniq
              end
            end
            
            f.trackers = Tracker.find(:all)
            custom_field_map[field.Name] = f
            f.save!
          end
          puts
          
          # set an RT ticket id field as a Redmine issue custom field.
          r = IssueCustomField.find(:first, :conditions => { :name => "RT ID" })
          # make it a string so it's searchable only add if it's not found
          r ||= IssueCustomField.new(:name => 'RT ID',
                                   :field_format => 'string',
                                   :searchable => true,
                                   :is_filter => true) if r.nil?
          r.trackers = Tracker.find(:all)
          
          r.save!
          custom_field_map['RT ID'] = r
          ### end custom field
        
          # Tickets - migrate by queue
          RTQueues.find_each do |queue| # find_each
            next if queue.name == '___Approvals' # we don't migrate this queue
            # get an identifier for the queue
            prompt('Redmine target project identifier for %s queue' % queue.name, :default => queue.name.downcase.dasherize.gsub(/[ ]/,'-')) {|identifier| RTMigrate.target_project_identifier identifier}
            
            # turn on custom fields for this project
            @target_project.issue_custom_fields << custom_field_map.values
            
            print "Migrating tickets"
            queue.tickets.find_each do |ticket|
              next if ticket.status == 'deleted' # we don't migrate deleted tickets
              print '.'
              STDOUT.flush
              
              # create the new issue
              i = Issue.new :project => @target_project,
                              :subject => encode((ticket.subject + ': RT ' + ticket.id.to_s)[0, limit_for(Issue, 'subject')]),
                              :description => 'RT migrate. If this text is present, no comment was made on RT ticket creation',
                              :priority => normalize_rt_priority(ticket.priority) || DEFAULT_PRIORITY,
                              :created_on => ticket.created,
                              :start_date => ticket.started
                              
              
              # each RT ticket has a 'Create' transaction, which has creator or it has an AddWatcher of Requestor type
              # Redmine only lets us have one author, so other watchers will be added later
              # TODO this assumes that the last AddWatcher isn't matched with a DelWatcher that would have no one requesting the ticket
              r = ticket.transactions.find(:last, :conditions => {:objecttype => 'RT::Ticket', :type => 'AddWatcher', :field => 'Requestor'})
              # if add watcher is still not there, go with created user
              r ||= ticket.transactions.find(:first, :conditions => {:objecttype => 'RT::Ticket', :type => 'Create'})
              
              i.author = find_or_create_user(r.newvalue || r.creator) # requester
              i.status = STATUS_MAPPING[ticket.status] || DEFAULT_STATUS
              
              # only copy over due dates that make sense
              if ticket.due > ticket.started
                i.due_date = ticket.due
              end
              
              # RT has no concept of a tracker. so default it
              i.tracker = DEFAULT_TRACKER
              
              # time lives at ticket and transactions for RT
              i.estimated_hours = ticket.timeestimated / 60
              
              # if importing into a blank system this works 1 to 1, otherwise an RT ID field is created to track old numbers
              i.id = ticket.id unless Issue.exists?(ticket.id)
              
              next unless Time.fake(ticket.lastupdated) { i.save! }
              TICKET_MAP[ticket.id] = i
              migrated_tickets += 1
              
              # Owner
              unless ticket.owner.blank?
                i.assigned_to = find_or_create_user(ticket.owner, true)
                Time.fake(ticket.lastupdated) { i.save! }
              end
              
              # Comments and status/resolution changes
              ticket.transactions.each do |changeset|
                next unless changeset.objecttype == "RT::Ticket" # we're only interested in ticket transactions
                next if changeset.type.include?('EmailRecord') # we're not tracking this (dup info)
                
                # each transaction can have 1..N attachments (refer to model)
                # a transaction = a journal entry
                n = Journal.new :created_on => changeset.created
                n.user = find_or_create_user(changeset.creator)
                n.journalized = i # this entry for this issue
                
                # are any of the attachments files
                changeset.attachments.each do |attachment|
                  next if attachment.content.blank? # looking for content
                  
                  if attachment.filename 
                    # looking for images/files/whatever
                    
                    a = nil
                    attachment.open {
                      a = Attachment.new :created_on => attachment.time
                      a.file = attachment
                      a.author = find_or_create_user(attachment.creator)
                      a.container = i
                      a.description = 'RT migrate: ' + attachment.filename
                      migrated_ticket_attachments += 1 if a.save!
                    }
                    
                    # lets make it show if save worked and it's an image
                    if a && attachment.contenttype.include?('image') then n.notes || i.description << ' !'+attachment.filename+'!' end
                  else
                    if changeset.type == 'Create'
                      # note goes with description
                      i.description = convert_wiki_text(encode(attachment.content), attachment.contenttype, attachment.contentencoding)
                    else
                      # content is a note
                      n.notes = convert_wiki_text(encode(attachment.content), attachment.contenttype, attachment.contentencoding)
                    end
                  end
                    
                end
                
                ## give the ticket to someone else, steal the ticket
                if (changeset.type == 'Give' || changeset.type == 'Steal') && changeset.field == 'Owner'
                  n.details << JournalDetail.new(:property => 'attr',
                                                 :prop_key => 'assigned_to_id',
                                                 :old_value => find_or_create_user(changeset.oldvalue) {|u| u ? u.id : nil },
                                                 :value => find_or_create_user(changeset.newvalue) {|u| u ? u.id : nil })
                end
                
                ## Could be a status change
                if changeset.type == 'Status' &&
                     STATUS_MAPPING[changeset.oldvalue] &&
                     STATUS_MAPPING[changeset.newvalue] &&
                     (STATUS_MAPPING[changeset.oldvalue] != STATUS_MAPPING[changeset.newvalue])
                  n.details << JournalDetail.new(:property => 'attr',
                                                 :prop_key => 'status_id',
                                                 :old_value => STATUS_MAPPING[changeset.oldvalue].id,
                                                 :value => STATUS_MAPPING[changeset.newvalue].id)
                end # end status change
                
                ## set estimated time on ticket
                if changeset.type == 'Set' && changeset.field == 'TimeEstimated'
                  i.estimated_hours = changeset.newvalue.to_f / 60
                  
                  n.details << JournalDetail.new(:property => 'attr',
                                                 :prop_key => 'estimated_hours',
                                                 :old_value => changeset.oldvalue.to_f / 60,
                                                 :value => changeset.newvalue.to_f / 60)
                end
                
                ## change the subject header
                if changeset.type == 'Set' && changeset.field == 'Subject'
                  i.estimated_hours = changeset.newvalue.to_f / 60
                  
                  n.details << JournalDetail.new(:property => 'attr',
                                                 :prop_key => 'subject',
                                                 :old_value => changeset.oldvalue,
                                                 :value => changeset.newvalue)
                end
                
                # time logged at a ticket level and with comments
                if changeset.timetaken > 0 || (changeset.type == 'Set' && changeset.field == 'TimeWorked')
                  # TODO: assumes changest.OldValue = 0
                  (TimeEntry.new :project => @target_project,
                                      :user => find_or_create_user(changeset.creator),
                                      :issue => i,
                                      :hours => (changeset.timetaken.to_f + changeset.newvalue.to_f) / 60, # only one of these values set, both default to 0
                                      :comments => 'RT logged time',
                                      :spent_on => changeset.created,
                                      :activity => TimeEntryActivity.last).save!
                  
                end
                
                # add watchers since we don't have multiple author's to one issue
                # this is NOT the same as 'star' watching a ticket in RT, but thats how it maps to redmine
                # RT has it's own 'star' watch an issue that is not migrated
                if changeset.type == 'AddWatcher'
                  (Watcher.new :watchable_type => 'Issue',
                                  :watchable_id => i.id,
                                  :user_id => find_or_create_user(changeset.newvalue).id).save
                end
                
                if changeset.type == 'DelWatcher' 
                  Watcher.destroy_all({:watchable_type => 'Issue', :user_id => find_or_create_user(changeset.newvalue).id, :watchable_id => i.id})
                end
                
                # save it
                n.save! unless n.details.empty? && n.notes.blank?
                  
              end # end transaction (changeset) loop
              
              # set custom fields for the ticket * objectcustomfieldvalues
              custom_values = ticket.objectcustomfieldvalues.inject({}) do |h, custom|
                cf = RTCustomFields.find_by_id(custom.CustomField)
                if custom_field = custom_field_map[cf.Name]
                  h[custom_field.id] = custom.Content
                  # count the values
                  migrated_custom_values += 1
                end
                h
              end
              
              # lets add RT ID
              custom_values[custom_field_map['RT ID'].id] = ticket.id
              
              i.custom_field_values = custom_values
              i.save_custom_field_values
              Time.fake(ticket.lastupdated) { i.save! }
            end # end ticket migration
            
            # update issue id sequence if needed (postgresql)
            Issue.connection.reset_pk_sequence!(Issue.table_name) if Issue.connection.respond_to?('reset_pk_sequence!')
            puts
          end # end queue migrate
          
          # now that all the tickets are over, lets link them up
          RTLinks.find_each do |link|
            begin
              # we can only link tickets that got migrated, of a certain type, that aren't equal to each other
              if (RELATION_TYPE_MAPPING[link.type] && TICKET_MAP[link.localbase] && TICKET_MAP[link.localtarget]) &&
                  (link.localbase != link.localtarget)
              
                (IssueRelation.new :issue_from => TICKET_MAP[link.localbase],
                                    :issue_to => TICKET_MAP[link.localtarget],
                                    :relation_type => RELATION_TYPE_MAPPING[link.type]).save!
              end
        
              # link of 'MemberOf' Type is really a parent id for the issue
              if link.type == 'MemberOf' && TICKET_MAP[link.localbase] && TICKET_MAP[link.localtarget]
                TICKET_MAP[link.localbase].parent_issue_id = TICKET_MAP[link.localtarget].id
                Time.fake(link.lastupdated) { TICKET_MAP[link.localbase].save! }
              end
          
              # merged into works a little different if target and base are the same.
              if (link.type == 'MergedInto' && TICKET_MAP[link.base[link.base.rindex('/')+1..link.base.length].to_i] && TICKET_MAP[link.localtarget])  &&
                  (link.localbase == link.localtarget)
                # for whatever reason RT decided it legitimate to have a link have itself as target and base
                # have to go the Base/Target field to find which to duplicate
                (IssueRelation.new :issue_from => TICKET_MAP[link.base[link.base.rindex('/')+1..link.base.length].to_i],
                                    :issue_to => TICKET_MAP[link.localtarget],
                                    :relation_type => RELATION_TYPE_MAPPING[link.type]).save!
              
              end
            rescue
              raise link.inspect
            end
          end
        
        end # end transaction
        
        puts
        puts "Tickets:         #{migrated_tickets}/" + RTTickets.count(:conditions => "Status != 'Deleted' ").to_s # we dont migrate deleted tickets
        puts "Ticket files:    #{migrated_ticket_attachments}/" + RTAttachments.count(:conditions => 'Filename is Not Null').to_s
        puts "Custom values:   #{migrated_custom_values}/#{RTObjectCustomFieldValues.count}"
        
      end ### end self.migrate
      
      # make sure we have connections
      def self.establish_connection
        constants.each do |const|
          klass = const_get(const)
          next unless klass.respond_to? 'establish_connection'
          klass.establish_connection connection_params
        end
      end
      
      # user is prompted for redmine project name to migrate RT tickets => Redmine issues
      def self.target_project_identifier(identifier)
        project = Project.find_by_identifier(identifier)
        if !project
          # create the target project
          puts "Creating new project"
          project = Project.new :name => identifier.humanize,
                                :description => ''
          project.identifier = identifier
          puts "Unable to create a project with identifier '#{identifier}'!" unless project.save!
          # enable issues and wiki for the created project
          project.enabled_module_names = ['issue_tracking', 'wiki', 'time_tracking']
        else
          puts
          puts "This project already exists in your Redmine database."
          print "Are you sure you want to append data to this project ? [Y/n] "
          STDOUT.flush
          exit if STDIN.gets.match(/^n$/i)
        end
        project.trackers << TRACKER_BUG unless project.trackers.include?(TRACKER_BUG)
        project.trackers << TRACKER_FEATURE unless project.trackers.include?(TRACKER_FEATURE)
        project.trackers << TRACKER_SUPPORT unless project.trackers.include?(TRACKER_SUPPORT)
        @target_project = project.new_record? ? nil : project
        @target_project.reload
      end
      
      # what we need to connect to RT3
      def self.connection_params
        if %w(sqlite sqlite3).include?(rt_adapter)
          {:adapter => rt_adapter,
           :database => rt_db_path}
        else
          {:adapter => rt_adapter,
           :database => rt_db_name,
           :host => rt_db_host,
           :port => rt_db_port,
           :username => rt_db_username,
           :password => rt_db_password,
           :schema_search_path => rt_db_schema
          }
        end
      end
      
      # this allows going to the data source via Redmine models
      # and getting the string length limit as set by database
      # ie: limit_for(User, 'mail')
      #     => 60
      def self.limit_for(klass, attribute)
        klass.columns_hash[attribute.to_s].limit
      end
      
      # encode to make sure we have good data
      def self.encoding(charset)
        @ic = Iconv.new('UTF-8', charset)
      rescue Iconv::InvalidEncoding
        puts "Invalid encoding!"
        return false
      end
      
      # normlize integer based priorities with redmine contex based priorities
      def self.normalize_rt_priority(priority)
        # @TODO take the initial priority, final pirority and current priority
        # => normalize into a 0-5 value
        
        # 'low' => priorities[0],
        # 'normal' => priorities[1],
        # 'high' => priorities[2],
        # 'urgent' => priorities[3],
        # 'immediate' => priorities[4]
        
        # just return a normal for now
        PRIORITY_MAPPING[1]
      end
      
      # Following are get/set for user collected prompts
      def self.set_rt_directory(path)
        @@rt_directory = path
        raise "This directory doesn't exist!" unless File.directory?(path)
        # RT stores attatchments in database
        # raise "#{rt_attachments_directory} doesn't exist!" unless File.directory?(rt_attachments_directory)
        @@rt_directory
      rescue Exception => e
        puts e
        return false
      end

      def self.rt_directory
        @@rt_directory
      end
      
      # queue to serve as source of tickets
      def self.set_rt_queue(queue)
        @@rt_queue = queue
      end
      
      def self.get_rt_queue
        return @@rt_queue
      end
      
      def self.rt_queue
        @@rt_queue
      end

      def self.set_rt_adapter(adapter)
        return false if adapter.blank?
        raise "Unknown adapter: #{adapter}!" unless %w(sqlite sqlite3 mysql postgresql).include?(adapter)
        # If adapter is sqlite or sqlite3, make sure that rt.db exists
        raise "#{rt_db_path} doesn't exist!" if %w(sqlite sqlite3).include?(adapter) && !File.exist?(rt_db_path)
        @@rt_adapter = adapter
      rescue Exception => e
        puts e
        return false
      end

      def self.set_rt_db_host(host)
        return nil if host.blank?
        @@rt_db_host = host
      end

      def self.set_rt_db_port(port)
        return nil if port.to_i == 0
        @@rt_db_port = port.to_i
      end

      def self.set_rt_db_name(name)
        return nil if name.blank?
        @@rt_db_name = name
      end

      def self.set_rt_db_username(username)
        @@rt_db_username = username
      end

      def self.set_rt_db_password(password)
        @@rt_db_password = password
      end

      def self.set_rt_db_schema(schema)
        @@rt_db_schema = schema
      end

      mattr_reader :rt_directory, :rt_adapter, :rt_db_host, :rt_db_port, :rt_db_name, :rt_db_schema, :rt_db_username, :rt_db_password, :rt_queue

      def self.rt_db_path; "#{rt_directory}/db/rt.db" end
      def self.rt_attachments_directory; "#{rt_directory}/attachments" end
      
      # when migrating tickets and other RT data lets create members if needed
      def self.find_or_create_user(rtuserid, project_member = false)
        rtuser = RTUsers.find_by_id(rtuserid)
        # return anonymous if not found
        return User.anonymous if !rtuser
        # return redmine system user if that's the case
        return User.find(:first, :conditions => {:admin => true}) if rtuser.name == 'RT_System'
        # return nil if it's nobody
        return nil if rtuser.name == 'Nobody'
        
        # search redmine for this user
        u = User.find_by_mail(rtuser.emailaddress)
        
        if !u
          # Create a new user if not found
          mail = rtuser.emailaddress[0,limit_for(User, 'mail')]
        #  if mail_attr = RTUsers.find_by_Name(username)
        #    mail = mail_attr.value
        #  end
          mail = "#{mail}@foo.bar" unless mail.include?("@")

          name = rtuser.name
        #  if name_attr = RTUsers.find_by_Name(username)
        #    name = name_attr.value
        #  end
          name =~ (/(.*)(\s+\w+)?/)
          fn = $1.strip
          ln = ($2 || '-').strip
          
          u = User.new :mail => mail.gsub(/[^-@a-z0-9_\.]/i, '-'), # sub out invalid characters
                       :firstname => fn[0, limit_for(User, 'firstname')].gsub(/[^\w\s\'\-]/i, '-'),
                       :lastname => ln[0, limit_for(User, 'lastname')].gsub(/[^\w\s\'\-]/i, '-')

          u.login = rtuser.name[0,limit_for(User, 'login')].gsub(/[^a-z0-9_\-@\.]/i, '-')
          u.password = 'rt_user'
          # RT permissions not boiled down to one action
          # u.admin = true if TracPermission.find_by_username_and_action(username, 'admin')
          
          # finally, a default user is used if the new user is not valid
          u = User.find(:first) unless u.save!
        end
        # Make sure user is a member of the project
        if project_member && !u.member_of?(@target_project)
          # RT role mapping not great, so just make them a reporter
          role = ROLE_MAPPING['reporter']
          
          Member.create(:user => u, :project => @target_project, :roles => [role])
          u.reload
        end
        u
      end # end find_or_create_user
      
      # mapping active record classes to RT3
      class RTUsers < ActiveRecord::Base
        set_table_name :users
      end
      
      # RT's concept of custom fields
      class RTCustomFields < ActiveRecord::Base
        set_table_name :customfields
        
        has_many :customfieldvalues, :class_name => "RTCustomFieldValues", :foreign_key => :customfield
        has_many :objectcustomfieldvalues, :class_name => "RTObjectCustomFieldValues", :foreign_key => :customfield
      end
      
      # each custom field has a list of values
      class RTCustomFieldValues < ActiveRecord::Base
        set_table_name :customfieldvalues
        
        belongs_to :rtcustomfields # foreign key - CustomField
      end
      
      # RT Queue ~= Redmine Project
      class RTQueues < ActiveRecord::Base
        set_table_name :queues
        
        has_many :tickets, :class_name => "RTTickets", :foreign_key => :queue
      end
      
      # RT Ticket = Redmine issue
      # RT does not have a concept of tracker, so all tickets are of one type
      class RTTickets < ActiveRecord::Base
        set_table_name :tickets
        set_inheritance_column :ruby_type
        
        belongs_to :rtqueues
        has_many :transactions, :class_name => "RTTransactions", :foreign_key => :objectid
        has_many :objectcustomfieldvalues, :class_name => "RTObjectCustomFieldValues", :foreign_key => :objectid
        
        # relations
        has_many :relations_from, :class_name => 'RTLinks', :foreign_key => 'localbase'
        has_many :relations_to, :class_name => 'RTLinks', :foreign_key => 'localtarget'
      end
      
      # RTLinks = Redmine subtasks/related issues
      class RTLinks < ActiveRecord::Base
        set_table_name :links
        set_inheritance_column :ruby_type
        
        belongs_to :ticket_from, :class_name => 'RTTickets', :foreign_key => 'localbase'
        belongs_to :ticket_to, :class_name => 'RTTickets', :foreign_key => 'localtarget'
      end
      
      # custom field vlaues for tickets (and other RT objects)
      class RTObjectCustomFieldValues < ActiveRecord::Base
        set_table_name :objectcustomfieldvalues
        
        belongs_to :rttickets, :polymorphic => true
        belongs_to :customfields, :polymorphic => true
      end
      
      # all actions in RT tracked via transactions
      # transactions have attachemnts
      class RTTransactions < ActiveRecord::Base
        set_table_name :transactions
        set_inheritance_column :ruby_type
        
        # that is to say there are ticket transactions here was well as many others
        belongs_to :rttickets, :polymorphic => true
        has_many :attachments, :class_name => "RTAttachments", :foreign_key => :transactionid
      end
      
      # RT attachemnts is not just files, but also content
      class RTAttachments < ActiveRecord::Base
        set_table_name :attachments
        
        belongs_to :rttransactions # foreign key TransactionId
        
        def time; Time.at(read_attribute(:created)) end
        
        def size
          @file.stat.size
        end
        
        def content_type; read_attribute(:contenttype) end
        
        def original_filename; read_attribute(:filename) end
        
        def read(*args)
          @file.read(*args)
        end
        
        def open
          # RT stores files as LBLOB, so we write that out to a tempfile
          # that can then be attached to something
          tf = Tempfile.open(sanitize_filename(read_attribute(:filename))) {|f| 
            f.write(read_attribute(:content))
            f.flush
            f.rewind
            
            @file = f
            yield self
          }
        end
        
        private
        # make sure we don't have problems with file names
        def sanitize_filename(filename)
          filename.strip.tap do |name|
            # NOTE: File.basename doesn't work right with Windows paths on Unix
            # get only the filename, not the whole path
            name.sub! /\A.*(\\|\/)/, ''
            # Finally, replace all non alphanumeric, underscore
            # or periods with underscore
            name.gsub! /[^\w\.\-]/, '_'
          end
        end
      end
      
      private
        # encode to proper standard
        def self.encode(text)
          @ic.iconv text
        rescue
          text
        end
    end #RTMigrate Module

    # lets make sure the user has a created database
    puts
    if Redmine::DefaultData::Loader.no_data?
      puts "Redmine configuration need to be loaded before importing data."
      puts "Please, run this first:"
      puts
      puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
      exit
    else
      puts "Redmine configuration found. Moving on."
    end
    
    # convert html to textile
    if !Gem.available?('html2textile') then
      print "WARNING: html2textile gem not found, do you want to continue? (RT content transfered as html text) [y/N] "
      STDOUT.flush
      break unless STDIN.gets.match(/^y$/i)
      puts
    end
    
  # give the user one last chance to quit
    print "WARNING: Back up before doing this, are you sure you want to continue ? [y/N] "
    STDOUT.flush
    break unless STDIN.gets.match(/^y$/i)
    puts
    
    # make one funciton for outputing a question and getting a response
    def prompt(text, options = {}, &block)
      default = options[:default] || ''
      while true
        print "#{text} [#{default}]: "
        STDOUT.flush
        value = STDIN.gets.chomp!
        value = default if value.blank?
        break if yield value
      end
    end # end def prompt
    
    DEFAULT_PORTS = {'mysql' => 3306, 'postgresql' => 5432}

    # uses def prompt for getting/setting values
    prompt('RT database adapter (sqlite, sqlite3, mysql, postgresql)', :default => 'mysql') {|adapter| RTMigrate.set_rt_adapter adapter}
    unless %w(sqlite sqlite3).include?(RTMigrate.rt_adapter)
      # we need more info if it's not sqlite3
      prompt('RT database host', :default => 'localhost') {|host| RTMigrate.set_rt_db_host host}
      prompt('RT database port', :default => DEFAULT_PORTS[RTMigrate.rt_adapter]) {|port| RTMigrate.set_rt_db_port port}
      prompt('RT database name', :default => 'rt3') {|name| RTMigrate.set_rt_db_name name}
      prompt('RT database schema', :default => 'public') {|schema| RTMigrate.set_rt_db_schema schema}
      prompt('RT database username', :default => 'rt') {|username| RTMigrate.set_rt_db_username username}
      prompt('RT database password') {|password| RTMigrate.set_rt_db_password password}
    end
    prompt('RT database encoding', :default => 'UTF-8') {|encoding| RTMigrate.encoding encoding}
    puts
    
    # now lets do the migrate
    Setting.notified_events = [] # Turn off email notifications
    RTMigrate.migrate
  end
end
