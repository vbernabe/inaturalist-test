class PicasaController < ApplicationController
  before_filter :authenticate_user!
  
  # Configure Picasa linkage
  def options
    if @provider_authorization = current_user.has_provider_auth('google')
      @picasa_photos = begin
        PicasaPhoto.picasa_request_with_refresh(current_user.picasa_identity) do
          picasa = Picasa.new(@provider_authorization.token)
          response = picasa.recent_photos(@provider_authorization.provider_uid, max_results: 18, thumbsize: '72c')
          response.try(:entries)
        end
      rescue RubyPicasa::PicasaError => e
        raise e unless e.message =~ /authentication/i
        nil
      end
    end
  end
  
  def photo_fields
    context = params[:context] || 'user'
    pa = current_user.has_provider_auth('google')
    if pa.nil?
      @provider = 'picasa'
      uri = Addressable::URI.parse(request.referrer) # extracts params and puts them in the hash uri.query_values
      uri.query_values ||= {}
      uri.query_values = uri.query_values.merge({:source => @provider, :context => context})
      @auth_url = ProviderAuthorization::AUTH_URLS['google']
      session[:return_to] = uri.to_s 
      render(:partial => "photos/auth") and return
    end
    if context == 'user' && params[:q].blank? # search is blank, so show all albums
      @albums = picasa_albums(current_user)
      render :partial => 'picasa/albums' and return
    elsif context == 'friends'
      @friend_id = params[:object_id]
      @friend_id = nil if @friend_id=='null'
      if @friend_id.nil?  # if context is friends, but no friend id specified, we want to show the friend selector
        @friends = picasa_friends(current_user)
        render :partial => 'picasa/friends' and return
      else
        @albums = picasa_albums(current_user, @friend_id)
        friend_data = current_user.picasa_client.user(@friend_id)
        @friend_name = friend_data.author.name 
        render :partial => 'picasa/albums' and return
      end
    else # context='public' or context='user' with a search query
      picasa = current_user.picasa_client
      search_params = {}
      per_page = params[:limit] ? params[:limit].to_i : 10
      search_params[:max_results] = per_page
      search_params[:start_index] = (params[:page] || 1).to_i * per_page - per_page + 1
      search_params[:thumbsize] = RubyPicasa::Photo::VALID.join(',')
      if context == 'user'
        search_params[:user_id] = current_user.picasa_identity.provider_uid
      end
      
      begin
        Timeout::timeout(10) do
          results = PicasaPhoto.picasa_request_with_refresh(current_user.picasa_identity) do
            picasa.search(params[:q], search_params)
          end
          if results
            @photos = results.photos.map do |api_response|
              next unless api_response.is_a?(RubyPicasa::Photo)
              PicasaPhoto.new_from_api_response(api_response, :user => current_user)
            end.compact
          end
        end
      rescue RubyPicasa::PicasaError => e
        # Ruby Picasa seems to have a bug in which it won't recognize a feed element with no content, e.g. a search with no results
        raise e unless e.message =~ /Unknown feed type/
      rescue Timeout::Error => e
        @timeout = e
      end
    end
    
    @synclink_base = params[:synclink_base] unless params[:synclink_base].blank?

    respond_to do |format|
      format.html do
        render :partial => 'photos/photo_list_form', 
               :locals => {
                 :photos => @photos, 
                 :index => params[:index],
                 :synclink_base => @synclink_base,
                 :local_photos => false
               }
      end
    end
  end

  # Return an HTML fragment containing photos in the album with the given fb native album id (i.e., params[:id])
  def album
    @friend_id = params[:object_id] unless (params[:object_id] == 'null' || params[:object_id].blank?)
    if @friend_id
      friend_data = current_user.picasa_client.user(@friend_id)
      @friend_name = friend_data.author.name 
    end
    per_page = (params[:limit] ? params[:limit].to_i : 10)
    search_params = {
      :max_results => per_page,
      :start_index => ((params[:page] || 1).to_i * per_page - per_page + 1),
      :picasa_user_id => @friend_id
    }
    @photos = PicasaPhoto.get_photos_from_album(current_user, params[:id], search_params) 
    @synclink_base = params[:synclink_base] unless params[:synclink_base].blank?
    respond_to do |format|
      format.html do
        render :partial => 'photos/photo_list_form', 
               :locals => {
                 :photos => @photos, 
                 :index => params[:index],
                 :synclink_base => nil, 
                 :local_photos => false,
                 :organized_by_album => true
               }
      end
    end
  end

  protected 

  # fetch picasa albums
  # user is used to authenticate the request
  # picasa_user_id specifies the picasa user whose albums to fetch
  # (if nil, it fetches the authenticating user's albums)
  def picasa_albums(options = {})
    return [] unless current_user.has_provider_auth('google')
    PicasaPhoto.picasa_request_with_refresh(current_user.picasa_identity) do
      picasa_user_id = options[:picasa_user_id] || current_user.picasa_identity.provider_uid
      picasa_identity = current_user.picasa_identity
      user_data = if picasa_user_id && picasa_identity
        PicasaPhoto.picasa_request_with_refresh(picasa_identity) do
          picasa_identity.reload
          picasa = Picasa.new(picasa_identity.token)
          picasa.user(picasa_user_id)
        end
      end
      albums = []
      unless user_data.nil?
        user_data.albums.select{|a| a.numphotos.to_i > 0}.each do |a|
          albums << {
            'aid' => a.id,
            'name' => a.title,
            'cover_photo_src' => a.thumbnails.first.url
          }
        end
      end
      albums
    end
  rescue RubyPicasa::PicasaError => e
    raise e unless e.message =~ /authentication/
    Rails.logger.error "[ERROR #{Time.now}] Failed to refresh access token for #{user.picasa_identity}"
    []
  end

  def picasa_friends(user)
    return [] unless (pa = current_user.has_provider_auth('google'))
    picasa = GData::Client::Photos.new
    picasa.auth_token = pa.token
    contacts_data = picasa.get("http://picasaweb.google.com/data/feed/api/user/default/contacts").to_xml 
    friends = []
    contacts_data.elements.each('entry'){|e|
      friends << {
        'id' => e.elements['gphoto:user'].text, # this is a feed url that id's the photo
        'name' => e.elements['gphoto:nickname'].text,
        'pic_url' => e.elements['gphoto:thumbnail'].text
      }
    }
    friends
  end

end
