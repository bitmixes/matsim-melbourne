makeMatsimNetwork<-function(test_area_flag=F,focus_area_flag=F,shortLinkLength=0.1,
                            add_z_flag=F,add.pt.flag=F,write_xml=F,write_sqlite=F){
  
  # test_area_flag=F
  # focus_area_flag=F
  # shortLinkLength=20
  # add_z_flag=F
  # add.pt.flag=F
  # ivabm_pt_flag=T
  # write_xml=T
  # write_sqlite=T
  
  message("========================================================")
  message("                **Network Generation Setting**")
  message("--------------------------------------------------------")
  message(paste0("- Cropping to a test area:                        ",test_area_flag))
  message(paste0("- Detailed network only in the focus area:        ", focus_area_flag))
  message(paste0("- Shortest link lenght in network simplification: ", shortLinkLength))
  message(paste0("- Adding elevation:                               ", add_z_flag))
  message(paste0("- Adding PT from GTFS:                            ", add.pt.flag))
  message(paste0("- Writing outputs in MATSim XML format:           ", write_xml))
  message(paste0("- Writing outputs in SQLite format:               ", write_sqlite))
  message("========================================================")
  # 
  #libraries
  library(sf)
  library(lwgeom)
  library(dplyr)
  library(data.table)
  library(stringr)
  library(igraph)
  library(raster)
  library(XML)
  library(rgdal)
  
  #functions
  source('./functions/buildDefaultsDF.R')
  source('./functions/processOsmTags.R')
  source('./functions/simplifyNetwork.R')
  source('./functions/exportSQlite.R')
  source('./functions/exportXML.R')
  source('./functions/etc/getAreaBoundary.R')
  source('./functions/etc/IVABMIntegrator.R')
  source('./functions/etc/logging.R')
  source('./functions/cleanNetwork.R')
  source('./functions/gtfs2PtNetowrk.R')
  

  
  # Adjusting boundaries  -------------------------------
  
  test_area_boundary <- st_as_sfc("SRID=28355;POLYGON((318877.2 5814208.5, 321433.7 5814021.4, 321547.1 5812332.6 ,318836.3 5812083.8,  318877.2 5814208.5))")
  
  # https://github.com/JamesChevalier/cities/tree/master/australia/victoria
  focus_area_shire <- "australia/victoria/city-of-melbourne_victoria.poly"  
  
  # Reading inputs ----------------------------------------------------------
  
  # Reading the planar input (unproccessed)
  osm_metadata <- st_read('data/melbourne.sqlite',layer="roads")%>%st_drop_geometry() # geometries are not important in this, we will use osm ids
  # Reading the nonplanar input (processed data by Alan)
  links <- st_read('data/network.sqlite' , layer="edges") # links
  nodes <- st_read('data/network.sqlite' , layer="nodes") # nodes
  
  # making the simplified network -------------------------------------------
  
  # node clusters based on those that are connected with link with less than 20 meters length
  system.time(
    df <- simplifyNetwork(links, nodes, osm_metadata, shortLinkLength)
  )
  nodes <- df[[1]]
  links <- df[[2]]

  
  # Croping to the test_area_boundary  --------------------------------------------
  
  if(test_area_flag){
    nodes <- nodes %>%
      filter(lengths(st_intersects(., test_area_boundary)) > 0)
    links <- links %>%
      filter(from_id%in%nodes$id & to_id%in%nodes$id)
  }
  
  # OSM tags processing and attributes assingment ---------------------------
  
  osm_metadata <- osm_metadata %>% filter(osm_id%in%links$osm_id)
  
  # Creating defaults dataframe
  defaults_df <- buildDefaultsDF()
  # Assigning attributes based on defaults df and osm tags
  system.time(
    osm_attrib <- processOsmTags(osm_metadata, defaults_df) 
  )
  links <- links %>%
    left_join(osm_attrib, by="osm_id")
  
  
  if(focus_area_flag){
    # Getting the boundary area
    focus_area_boundary <- getAreaBoundary(focus_area_shire, 28355)
    # Filtering links
    links <- links %>%
      filter((lengths(st_intersects(., focus_area_boundary)) > 0) |  highway %in% defaults_df$highwayType[1:8])
    # Filtering nodes
    nodes<- nodes %>%
      filter(id%in%links$from_id | id%in%links$to_id)
  }
  
  #TODO: Fix the DEM so it covers the entire area.
  ## Adding elevation
  if(add_z_flag){
    elevation <- raster('data/DEMx10EPSG28355.tif') 
    
    # Assiging z coordinations to nodes
    nodes$z <- round(raster::extract(elevation ,as(nodes, "Spatial"),method='bilinear'))/10 # TODO Not working properly
    nodes <- nodes %>% dplyr::select(id, x = X, y = Y, z, GEOMETRY) %>% distinct(id, x, y, z, GEOMETRY) # id's should be unique
    
  }else{
    nodes <- nodes %>% dplyr::select(id, x = X, y = Y, GEOMETRY) %>% distinct(id, x, y, GEOMETRY) # id's should be unique
  }
  
  #st_write(links,"data/networkSimplified.sqlite",delete_layer=TRUE,layer="edges")
  #st_write(nodes,"data/networkSimplified.sqlite",delete_layer=TRUE,layer="nodes")
  
  # Adding a reverse link for bi-directional links
  bi_links <- links %>% filter(oneway==2) %>% 
    rename(from_id=to_id, to_id=from_id, toX=fromX, toY=fromY, fromX=toX, fromY=toY) %>% 
    #mutate(id=paste0("p_",from_id,"_",to_id,"_",row_number())) %>% 
    st_drop_geometry()%>% 
    dplyr::select(osm_id, from_id, to_id, fromX, fromY, toX, toY, length, highway, freespeed, permlanes, capacity, bikeway, isCycle, isWalk, isCar, modes)
  
  links <- links %>% 
    #mutate(id=paste0("p_",from_id,"_",to_id,"_",row_number())) %>% 
    st_drop_geometry() %>% 
    dplyr::select(osm_id, from_id, to_id, fromX, fromY, toX, toY, length, highway, freespeed, permlanes, capacity, bikeway, isCycle, isWalk, isCar, modes) %>% 
    rbind(bi_links)
  
  

  #add.pt.flag <- F
  
  if(add.pt.flag){
    links_pt <- gtfs2PtNetowrk(nodes) # ToDo studyRegion = st_union(st_convex_hull(nodes))
    links <- rbind(links, as.data.frame(links_pt)) %>% distinct()
  }
  

  
  # Cleaning before writing
  system.time(
    df <- cleanNetwork(links, nodes, "")
  ) 
  nodes<- df[[1]]
  links<- df[[2]]

  if(ivabm_pt_flag){
    df2 <-integrateIVABM(st_drop_geometry(nodes),links)
    #nodes<- df[[1]]
    #links<- df[[2]]
  }
  
  ## writing outputs - sqlite
  if (write_sqlite) {
    cat('\n')
    echo(paste0('Writing the sqlite output: ', nrow(links), ' links and ', nrow(nodes),' nodes\n'))
    
    #st_write(,'./generatedNetworks/MATSimNetwork.sqlite', layer = 'links',driver = 'SQLite', layer_options = 'GEOMETRY=AS_XY', delete_layer = T)
    #st_write(, './generatedNetworks/MATSimNetwork.sqlite', layer = 'nodes',driver = 'SQLite', layer_options = 'GEOMETRY=AS_XY', delete_layer = T)
    exportSQlite(links, nodes, outputFileName = "MATSimNetwork_noPT_V1.3")
    echo(paste0('Finished generating the sqlite output\n'))
  }
  
  ## writing outputs - MATSim XML - TODO make the xml writer dynamic based on the optional network attributes
  if (write_xml) {
    #links_attrib_ng <- links_attrib_cleaned %>% st_set_geometry(NULL) # Geometry in XML will 
    cat('\n')
    echo(paste0('Writing the XML output: ', nrow(links), ' links and ', nrow(nodes),' nodes\n'))
    exportXML(links, st_drop_geometry(nodes), outputFileName = "MATSimNetwork_noPT_V1.3", add_z_flag)
    echo(paste0('Finished generating the xml output\n'))
  }
  
}