# Redmine - project management software
# Copyright (C) 2006-2009  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class ProjectsController < ApplicationController
  menu_item :overview
  menu_item :activity, :only => :activity
  menu_item :roadmap, :only => :roadmap
  menu_item :files, :only => [:list_files, :add_file]
  menu_item :settings, :only => :settings
  
  before_filter :find_project, :except => [ :index, :list, :add, :copy, :activity ]
  before_filter :find_optional_project, :only => :activity
  before_filter :authorize, :except => [ :index, :list, :add, :copy, :archive, :unarchive, :destroy, :activity ]
  before_filter :authorize_global, :only => :add
  before_filter :require_admin, :only => [ :copy, :archive, :unarchive, :destroy ]
  accept_key_auth :activity
  
  after_filter :only => [:add, :edit, :archive, :unarchive, :destroy] do |controller|
    if controller.request.post?
      controller.send :expire_action, :controller => 'welcome', :action => 'robots.txt'
    end
  end
  
  helper :sort
  include SortHelper
  helper :custom_fields
  include CustomFieldsHelper   
  helper :issues
  helper :queries
  include QueriesHelper
  helper :repositories
  include RepositoriesHelper
  include ProjectsHelper
  
  # Lists visible projects
  def index
    respond_to do |format|
      format.html { 
        @projects = Project.visible.find(:all, :order => 'lft') 
      }
      format.xml  {
        @projects = Project.visible.find(:all, :order => 'lft')
      }
      format.atom {
        projects = Project.visible.find(:all, :order => 'created_on DESC',
                                              :limit => Setting.feeds_limit.to_i)
        render_feed(projects, :title => "#{Setting.app_title}: #{l(:label_project_latest)}")
      }
    end
  end
  
  # Add a new project
  def add
    @issue_custom_fields = IssueCustomField.find(:all, :order => "#{CustomField.table_name}.position")
    @trackers = Tracker.all
    @project = Project.new(params[:project])
    if request.get?
      @project.identifier = Project.next_identifier if Setting.sequential_project_identifiers?
      @project.trackers = Tracker.all
      @project.is_public = Setting.default_projects_public?
      @project.enabled_module_names = Setting.default_projects_modules
    else
      @project.enabled_module_names = params[:enabled_modules]
      if validate_parent_id && @project.save
        @project.set_allowed_parent!(params[:project]['parent_id']) if params[:project].has_key?('parent_id')
        # Add current user as a project member if he is not admin
        unless User.current.admin?
          r = Role.givable.find_by_id(Setting.new_project_user_role_id.to_i) || Role.givable.first
          m = Member.new(:user => User.current, :roles => [r])
          @project.members << m
        end
        respond_to do |format|
          format.html { 
            flash[:notice] = l(:notice_successful_create)
            redirect_to :controller => 'projects', :action => 'settings', :id => @project
          }
          format.xml  { head :created, :location => url_for(:controller => 'projects', :action => 'show', :id => @project.id) }
        end
      else
        respond_to do |format|
          format.html
          format.xml  { render :xml => @project.errors, :status => :unprocessable_entity }
        end
      end
    end	
  end
  
  def copy
    @issue_custom_fields = IssueCustomField.find(:all, :order => "#{CustomField.table_name}.position")
    @trackers = Tracker.all
    @root_projects = Project.find(:all,
                                  :conditions => "parent_id IS NULL AND status = #{Project::STATUS_ACTIVE}",
                                  :order => 'name')
    @source_project = Project.find(params[:id])
    if request.get?
      @project = Project.copy_from(@source_project)
      if @project
        @project.identifier = Project.next_identifier if Setting.sequential_project_identifiers?
      else
        redirect_to :controller => 'admin', :action => 'projects'
      end  
    else
      Mailer.with_deliveries(params[:notifications] == '1') do
        @project = Project.new(params[:project])
        @project.enabled_module_names = params[:enabled_modules]
        if validate_parent_id && @project.copy(@source_project, :only => params[:only])
          @project.set_allowed_parent!(params[:project]['parent_id']) if params[:project].has_key?('parent_id')
          flash[:notice] = l(:notice_successful_create)
          redirect_to :controller => 'admin', :action => 'projects'
        elsif !@project.new_record?
          # Project was created
          # But some objects were not copied due to validation failures
          # (eg. issues from disabled trackers)
          # TODO: inform about that
          redirect_to :controller => 'admin', :action => 'projects'
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to :controller => 'admin', :action => 'projects'
  end
	
  # Show @project
  def show
    if params[:jump]
      # try to redirect to the requested menu item
      redirect_to_project_menu_item(@project, params[:jump]) && return
    end
    
    @users_by_role = @project.users_by_role
    @subprojects = @project.children.visible
    @news = @project.news.find(:all, :limit => 5, :include => [ :author, :project ], :order => "#{News.table_name}.created_on DESC")
    @trackers = @project.rolled_up_trackers
    
    cond = @project.project_condition(Setting.display_subprojects_issues?)
    
    @open_issues_by_tracker = Issue.visible.count(:group => :tracker,
                                            :include => [:project, :status, :tracker],
                                            :conditions => ["(#{cond}) AND #{IssueStatus.table_name}.is_closed=?", false])
    @total_issues_by_tracker = Issue.visible.count(:group => :tracker,
                                            :include => [:project, :status, :tracker],
                                            :conditions => cond)
    
    TimeEntry.visible_by(User.current) do
      @total_hours = TimeEntry.sum(:hours, 
                                   :include => :project,
                                   :conditions => cond).to_f
    end
    @key = User.current.rss_key
    
    respond_to do |format|
      format.html
      format.xml
    end
  end

  def settings
    @issue_custom_fields = IssueCustomField.find(:all, :order => "#{CustomField.table_name}.position")
    @issue_category ||= IssueCategory.new
    @member ||= @project.members.new
    @trackers = Tracker.all
    @repository ||= @project.repository
    @wiki ||= @project.wiki
  end
  
  # Edit @project
  def edit
    if request.get?
    else
      @project.attributes = params[:project]
      if validate_parent_id && @project.save
        @project.set_allowed_parent!(params[:project]['parent_id']) if params[:project].has_key?('parent_id')
        respond_to do |format|
          format.html { 
            flash[:notice] = l(:notice_successful_update)
            redirect_to :action => 'settings', :id => @project
          }
          format.xml  { head :ok }
        end
      else
        respond_to do |format|
          format.html { 
            settings
            render :action => 'settings'
          }
          format.xml  { render :xml => @project.errors, :status => :unprocessable_entity }
        end
      end
    end
  end
  
  def modules
    @project.enabled_module_names = params[:enabled_modules]
    flash[:notice] = l(:notice_successful_update)
    redirect_to :action => 'settings', :id => @project, :tab => 'modules'
  end

  def archive
    if request.post?
      unless @project.archive
        flash[:error] = l(:error_can_not_archive_project)
      end
    end
    redirect_to(url_for(:controller => 'admin', :action => 'projects', :status => params[:status]))
  end
  
  def unarchive
    @project.unarchive if request.post? && !@project.active?
    redirect_to(url_for(:controller => 'admin', :action => 'projects', :status => params[:status]))
  end
  
  # Delete @project
  def destroy
    @project_to_destroy = @project
    if request.get?
      # display confirmation view
    else
      if params[:format] == 'xml' || params[:confirm]
        @project_to_destroy.destroy
        respond_to do |format|
          format.html { redirect_to :controller => 'admin', :action => 'projects' }
          format.xml  { head :ok }
        end
      end
    end
    # hide project in layout
    @project = nil
  end

  def add_file
    if request.post?
      container = (params[:version_id].blank? ? @project : @project.versions.find_by_id(params[:version_id]))
      attachments = Attachment.attach_files(container, params[:attachments])
      render_attachment_warning_if_needed(container)

      if !attachments.empty? && Setting.notified_events.include?('file_added')
        Mailer.deliver_attachments_added(attachments[:files])
      end
      redirect_to :controller => 'projects', :action => 'list_files', :id => @project
      return
    end
    @versions = @project.versions.sort
  end

  def save_activities
    if request.post? && params[:enumerations]
      Project.transaction do
        params[:enumerations].each do |id, activity|
          @project.update_or_create_time_entry_activity(id, activity)
        end
      end
      flash[:notice] = l(:notice_successful_update)
    end
    
    redirect_to :controller => 'projects', :action => 'settings', :tab => 'activities', :id => @project
  end

  def reset_activities
    @project.time_entry_activities.each do |time_entry_activity|
      time_entry_activity.destroy(time_entry_activity.parent)
    end
    flash[:notice] = l(:notice_successful_update)
    redirect_to :controller => 'projects', :action => 'settings', :tab => 'activities', :id => @project
  end
  
  def list_files
    sort_init 'filename', 'asc'
    sort_update 'filename' => "#{Attachment.table_name}.filename",
                'created_on' => "#{Attachment.table_name}.created_on",
                'size' => "#{Attachment.table_name}.filesize",
                'downloads' => "#{Attachment.table_name}.downloads"
                
    @containers = [ Project.find(@project.id, :include => :attachments, :order => sort_clause)]
    @containers += @project.versions.find(:all, :include => :attachments, :order => sort_clause).sort.reverse
    render :layout => !request.xhr?
  end

  def roadmap
    @trackers = @project.trackers.find(:all, :order => 'position')
    retrieve_selected_tracker_ids(@trackers, @trackers.select {|t| t.is_in_roadmap?})
    @with_subprojects = params[:with_subprojects].nil? ? Setting.display_subprojects_issues? : (params[:with_subprojects] == '1')
    project_ids = @with_subprojects ? @project.self_and_descendants.collect(&:id) : [@project.id]
    
    @versions = @project.shared_versions || []
    @versions += @project.rolled_up_versions.visible if @with_subprojects
    @versions = @versions.uniq.sort
    @versions.reject! {|version| version.closed? || version.completed? } unless params[:completed]
    
    @issues_by_version = {}
    unless @selected_tracker_ids.empty?
      @versions.each do |version|
        issues = version.fixed_issues.visible.find(:all,
                                                   :include => [:project, :status, :tracker, :priority],
                                                   :conditions => {:tracker_id => @selected_tracker_ids, :project_id => project_ids},
                                                   :order => "#{Project.table_name}.lft, #{Tracker.table_name}.position, #{Issue.table_name}.id")
        @issues_by_version[version] = issues
      end
    end
    @versions.reject! {|version| !project_ids.include?(version.project_id) && @issues_by_version[version].blank?}
  end
  
  def activity
    @days = Setting.activity_days_default.to_i
    
    if params[:from]
      begin; @date_to = params[:from].to_date + 1; rescue; end
    end

    @date_to ||= Date.today + 1
    @date_from = @date_to - @days
    @with_subprojects = params[:with_subprojects].nil? ? Setting.display_subprojects_issues? : (params[:with_subprojects] == '1')
    @author = (params[:user_id].blank? ? nil : User.active.find(params[:user_id]))
    
    @activity = Redmine::Activity::Fetcher.new(User.current, :project => @project, 
                                                             :with_subprojects => @with_subprojects,
                                                             :author => @author)
    @activity.scope_select {|t| !params["show_#{t}"].nil?}
    @activity.scope = (@author.nil? ? :default : :all) if @activity.scope.empty?

    events = @activity.events(@date_from, @date_to)
    
    if events.empty? || stale?(:etag => [events.first, User.current])
      respond_to do |format|
        format.html { 
          @events_by_day = events.group_by(&:event_date)
          render :layout => false if request.xhr?
        }
        format.atom {
          title = l(:label_activity)
          if @author
            title = @author.name
          elsif @activity.scope.size == 1
            title = l("label_#{@activity.scope.first.singularize}_plural")
          end
          render_feed(events, :title => "#{@project || Setting.app_title}: #{title}")
        }
      end
    end
    
  rescue ActiveRecord::RecordNotFound
    render_404
  end
  
private
  def find_optional_project
    return true unless params[:id]
    @project = Project.find(params[:id])
    authorize
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def retrieve_selected_tracker_ids(selectable_trackers, default_trackers=nil)
    if ids = params[:tracker_ids]
      @selected_tracker_ids = (ids.is_a? Array) ? ids.collect { |id| id.to_i.to_s } : ids.split('/').collect { |id| id.to_i.to_s }
    else
      @selected_tracker_ids = (default_trackers || selectable_trackers).collect {|t| t.id.to_s }
    end
  end
  
  # Validates parent_id param according to user's permissions
  # TODO: move it to Project model in a validation that depends on User.current
  def validate_parent_id
    return true if User.current.admin?
    parent_id = params[:project] && params[:project][:parent_id]
    if parent_id || @project.new_record?
      parent = parent_id.blank? ? nil : Project.find_by_id(parent_id.to_i)
      unless @project.allowed_parents.include?(parent)
        @project.errors.add :parent_id, :invalid
        return false
      end
    end
    true
  end
end
