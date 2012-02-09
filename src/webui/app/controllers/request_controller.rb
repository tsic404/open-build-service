require 'base64'

class RequestController < ApplicationController
  include ApplicationHelper

  def add_reviewer_dialog
    @request_id = params[:id]
  end

  def add_reviewer
    begin
      opts = {}
      case params[:review_type]
        when "user" then opts[:user] = params[:review_user]
        when "group" then opts[:group] = params[:review_group]
        when "project" then opts[:project] = params[:review_project]
        when "package" then opts[:project] = params[:review_project]
                            opts[:package] = params[:review_package]
      end
      opts[:comment] = params[:review_comment] if params[:review_comment]

      BsRequest.addReview(params[:id], opts)
    rescue BsRequest::ModifyError => e
      flash[:error] = "Unable add reviewever '#{params[:id]}'"
    end
    redirect_to :controller => :request, :action => "show", :id => params[:id]
  end

  def modify_review
    valid_http_methods :post
    begin
      BsRequest.modifyReview(params[:id], params[:new_state], params)
      render :text => params[:new_state]
    rescue BsRequest::ModifyError => e
      render :text => e.message
    end
  end

  def show
    begin
      @req = find_cached(BsRequest, params[:id]) if params[:id]
    rescue ActiveXML::Transport::Error => e
      flash[:error] = "Can't find request #{params[:id]}"
      redirect_back_or_to :controller => "home", :action => "requests" and return
    end

    @id = Integer(@req.value("id"))
    @state = @req.state.value("name")
    @is_author = @req.creator().login == session[:login]
    @superseded_by = @req.state.value("superseded_by")

    @my_open_reviews, @other_open_reviews = @req.reviews_for_user_and_others(@user)
    @events = @req.events()
    if @spider_bot # Don't fetch diff, may take to long
      @actions = @req.actions(false)
    else
      @actions = @req.actions(true)
    end

    #TODO: Move to model:
    request_list = session[:requests]
    @request_before = nil
    @request_after  = nil
    index = request_list.index(@id) if request_list
    if index and index > 0
      @request_before = request_list[index-1]
    end
    if index
      # will be nul for after end
      @request_after = request_list[index+1]
    end
  end

  def sourcediff
    render :text => 'no ajax', :status => 400 and return unless request.xhr?
    render :partial => "shared/editor", :locals => {:text => params[:text], :mode => 'diff', :read_only => true, :height => 'auto', :width => '750px', :no_border => true}
  end

  def changerequest
    @req = find_cached(BsRequest, params[:id] ) if params[:id]
    unless @req
      flash[:error] = "Can't find request #{params[:id]}"
      redirect_to :action => :index and return
    end

    changestate = nil
    ['accepted', 'declined', 'revoked', 'new'].each do |s|
      if params.has_key? s
        changestate = s
        break
      end
    end

    Directory.free_cache(:project => @req.action.target.project, :package => @req.action.target.value('package'))
    if change_request(changestate, params)
      if params[:add_submitter_as_maintainer]
        if changestate != 'accepted'
           flash[:error] = "Will not add maintainer for not accepted requests"
        else
           add_maintainer(@req)
        end
      end
    end
    if changestate == 'accepted'
      flash[:note] = "Request #{params[:id]} accepted"

      # Check if we have to forward this request to other projects / packages
      params.keys.grep(/^forward_.*/).each do |fwd|
        tgt_prj, tgt_pkg = params[fwd].split('_#_') # split off 'forward_' and split into project and package
        description = @req.description.text
        if @req.has_element? 'state'
          who = @req.state.value("who")
          description += " (forwarded request %d from %s)" % [params[:id], who]
        end

        rev = Package.current_rev(@req.action.target.project, @req.action.target.package)
        req = BsRequest.new(:type => 'submit', :targetproject => tgt_prj, :targetpackage => tgt_pkg,
                             :project => @req.action.target.project, :package => @req.action.target.package,
                             :rev => rev, :description => description)
        req.save(:create => true)
        Rails.cache.delete('requests_new')
        # link_to isn't available here, so we have to write some HTML. Uses url_for to not hardcode URLs.
        flash[:note] += " and forwarded to <a href='#{url_for(:controller => 'package', :action => 'show', :project => tgt_prj, :package => tgt_pkg)}'>#{tgt_prj} / #{tgt_pkg}</a> (request <a href='#{url_for(:action => 'show', :id => req.value('id'))}'>#{req.value('id')}</a>)"
      end

      # Cleanup prj/pkg cache after auto-removal of source projects / packages (mostly from branches).
      # To keep things simple, we don't check if the src prj had more pkgs, etc..
      @req.each_action do |action|
        if action.value('type') == 'submit' and action.has_element?('options') and action.options.value('sourceupdate') == 'cleanup'
          Rails.cache.delete("#{action.source.project}_packages_mainpage")
          Rails.cache.delete("#{action.source.project}_problem_packages")
          Package.free_cache(:all, :project => action.source.project)
          Package.free_cache(action.source.package, :project => action.source.project) if action.source.package
        end
      end
    end
    redirect_to :action => 'show', :id => params[:id]
  end

  def diff
    # just for compatibility. OBS 1.X used this route for show
    redirect_to :action => :show, :id => params[:id]
  end

  def list
    redirect_to :controller => :home, :action => :requests and return unless request.xhr?  # non ajax request
    requests = BsRequest.list(params)
    elide_len = 44
    elide_len = params[:elide_len].to_i if params[:elide_len]
    session[:requests] = requests.each.map {|r| Integer(r.value(:id)) }.sort
    render :partial => 'shared/requests', :locals => {:requests => requests, :elide_len => elide_len}
  end

  def list_small
    redirect_to :controller => :home, :action => :requests and return unless request.xhr?  # non ajax request
    requests = BsRequest.list(params)
    render :partial => "shared/requests_small", :locals => {:requests => requests}
  end

  def delete_request_dialog
    @project = params[:project]
    @package = params[:package] if params[:package]
  end

  def delete_request
    begin
      req = BsRequest.new(:type => "delete", :targetproject => params[:project], :targetpackage => params[:package], :description => params[:description])
      req.save(:create => true)
      Rails.cache.delete "requests_new"
    rescue ActiveXML::Transport::Error => e
      message, code, api_exception = ActiveXML::Transport.extract_error_message e
      flash[:error] = message
      redirect_to :controller => :package, :action => :show, :package => params[:package], :project => params[:project] and return if params[:package]
      redirect_to :controller => :project, :action => :show, :project => params[:project] and return
    end
    redirect_to :controller => :request, :action => :show, :id => req.value("id")
  end

  def add_role_request_dialog
    @project = params[:project]
    @package = params[:package] if params[:package]
  end

  def add_role_request
    begin
      req = BsRequest.new(:type => "add_role", :targetproject => params[:project], :targetpackage => params[:package], :role => params[:role], :person => params[:user])
      req.save(:create => true)
      Rails.cache.delete "requests_new"
    rescue ActiveXML::Transport::NotFoundError => e
      message, code, api_exception = ActiveXML::Transport.extract_error_message e
      flash[:error] = message
      redirect_to :controller => :package, :action => :show, :package => params[:package], :project => params[:project] and return if params[:package]
      redirect_to :controller => :project, :action => :show, :project => params[:project] and return
    end
    redirect_to :controller => :request, :action => :show, :id => req.value("id")
  end

private

  def change_request(changestate, params)
    begin
      if BsRequest.modify( params[:id], changestate, :reason => params[:reason], :force => true )
        flash[:note] = "Request #{changestate}!" and return true
      else
        flash[:error] = "Can't change request to #{changestate}!"
      end
    rescue BsRequest::ModifyError => e
      flash[:error] = e.message
    end
    return false
  end

  def add_maintainer(req)
    if req.action.target.has_attribute?('package')
      target = find_cached(Package, req.action.target.package, :project => req.action.target.project)
    else
      target = find_cached(Project, req.action.target.project)
    end
    target.add_person(:userid => BsRequest.creator(req).login, :role => "maintainer")
    target.save
  end

end
