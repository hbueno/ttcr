//
//  ttcr3d.cpp
//  ttcr
//
//  Created by Bernard Giroux on 2014-04-03.
//  Copyright (c) 2014 Bernard Giroux. All rights reserved.
//


#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <thread>

#include "Grid3Drc.h"
#include "Grid3D.h"
#include "Rcv.h"
#include "Src.h"
#include "spmrt_io.h"
#include "structs_spmrt.h"
#include "utils_spmrt.h"

using namespace std;


template<typename T>
int body(const input_parameters &par) {
    
	std::vector< Src<T> > src;
    for ( size_t n=0; n<par.srcfiles.size(); ++ n ) {
        src.push_back( Src<T>( par.srcfiles[n] ) );
		string end = " ... ";
		if ( n < par.srcfiles.size() - 1 ) end = " ...\n";
        if ( par.verbose ) cout << "Reading source file " << par.srcfiles[n] << end;
        src[n].init();
    }
    if ( par.verbose ) cout << "done.\n";
	
	size_t const nTx = src.size();
	size_t num_threads = 1;
	if ( par.nt == 0 ) {
		size_t const hardware_threads = std::thread::hardware_concurrency();
		size_t const min_per_thread=5;
		size_t const max_threads = (nTx+min_per_thread-1)/min_per_thread;
		num_threads = std::min((hardware_threads!=0?hardware_threads:2), max_threads);
	} else {
		num_threads = par.nt < nTx ? par.nt : nTx;
	}
	
    size_t const blk_size = (nTx%num_threads ? 1 : 0) + nTx/num_threads;
    
	string::size_type idx;
    
    idx = par.modelfile.rfind('.');
    string extension = "";
    if(idx != string::npos) {
        extension = par.modelfile.substr(idx);
    }
    
    Grid3D<T,uint32_t> *g=nullptr;
    vector<Rcv<T>> reflectors;
    if (extension == ".vtr") {
#ifdef VTK
        g = recti<T>(par, num_threads);
#else
		cerr << "Error: Program not compiled with VTK support" << endl;
		return 1;
#endif
    } else if (extension == ".vtu") {
#ifdef VTK
        g = unstruct_vtu<T>(par, num_threads);
#else
		cerr << "Error: Program not compiled with VTK support" << endl;
		return 1;
#endif
    } else if (extension == ".msh") {
        g = unstruct<T>(par, reflectors, num_threads, src.size());
    } else {
        cerr << par.modelfile << " Unknown extenstion: " << extension << endl;
        return 1;
    }
    
    if ( g == nullptr ) {
        cerr << "Error: grid cannot be built\n";
		return 1;
    }
    
	Rcv<T> rcv( par.rcvfile );
    if ( par.verbose ) cout << "Reading receiver file " << par.rcvfile << " ... ";
    rcv.init( src.size() );
    if ( par.verbose ) cout << "done.\n";
    
    if ( par.verbose ) {
        if ( par.singlePrecision ) {
            cout << "Calculations will be done in single precision.\n";
        } else {
            cout << "Calculations will be done in double precision.\n";
        }
    }
	if ( par.verbose && num_threads>1 ) {
		cout << "Calculations will be done using " << num_threads
		<< " threads with " << blk_size << " shots per threads.\n";
	}
	
	vector<const vector<sxyz<T>>*> all_rcv;
	all_rcv.push_back( &(rcv.get_coord()) );
	for ( size_t n=0; n<reflectors.size(); ++n ) {
		all_rcv.push_back( &(reflectors[n].get_coord()) );
	}
	
    
	chrono::high_resolution_clock::time_point begin, end;
	std::vector<std::vector<std::vector<sxyz<T> > > > r_data(src.size());
    vector<vector<vector<vector<sxyz<T>>>>> rfl_r_data(reflectors.size());
	for ( size_t n=0; n<reflectors.size(); ++n ) {
        rfl_r_data[n].resize( src.size() );
    }
    vector<vector<vector<vector<sxyz<T>>>>> rfl2_r_data(reflectors.size());
	for ( size_t n=0; n<reflectors.size(); ++n ) {
        rfl2_r_data[n].resize( src.size() );
    }
	
    
    if ( par.verbose ) { cout << "Computing traveltimes ... "; cout.flush(); }
	if ( par.time ) { begin = chrono::high_resolution_clock::now(); }
	if ( par.saveRaypaths ) {
		if ( num_threads == 1 ) {
			for ( size_t n=0; n<src.size(); ++n ) {
				
                vector<vector<T>*> all_tt;
				all_tt.push_back( &(rcv.get_tt(n)) );
                vector<vector<vector<sxyz<T>>>*> all_r_data;
                all_r_data.push_back( &(r_data[n]) );
				
				for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
					all_tt.push_back( &(reflectors[nr].get_tt(n)) );
                    all_r_data.push_back( &(rfl_r_data[nr][n]) );
				}
				
				g->raytrace(src[n].get_coord(), src[n].get_t0(), all_rcv,
							all_tt, all_r_data);
				
				for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
					g->raytrace(reflectors[nr].get_coord(),
								reflectors[nr].get_tt(n), rcv.get_coord(),
								rcv.get_tt(n,nr+1), rfl2_r_data[nr][n]);
				}
			}
		} else {
			// threaded jobs
			
			std::vector<std::thread> threads(num_threads-1);
			size_t blk_start = 0;
			for ( size_t i=0; i<num_threads-1; ++i ) {
				
				size_t blk_end = blk_start + blk_size;
				
				threads[i]=thread( [&g,&src,&rcv,&r_data,&reflectors,&all_rcv,
									&rfl_r_data,&rfl2_r_data,
									blk_start,blk_end,i]{
                    
					for ( size_t n=blk_start; n<blk_end; ++n ) {
						
						vector<vector<T>*> all_tt;
						all_tt.push_back( &(rcv.get_tt(n)) );
                        vector<vector<vector<sxyz<T>>>*> all_r_data;
                        all_r_data.push_back( &(r_data[n]) );
						for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
							all_tt.push_back( &(reflectors[nr].get_tt(n)) );
                            all_r_data.push_back( &(rfl_r_data[nr][n]) );
						}
						
						g->raytrace(src[n].get_coord(), src[n].get_t0(), all_rcv,
									all_tt, all_r_data, i+1);
						
						for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
							g->raytrace(reflectors[nr].get_coord(),
										reflectors[nr].get_tt(n), rcv.get_coord(),
										rcv.get_tt(n,nr+1), rfl2_r_data[nr][n], i+1);
						}
					}
				});
				
				blk_start = blk_end;
			}
			for ( size_t n=blk_start; n<nTx; ++n ) {
                
				vector<vector<T>*> all_tt;
                all_tt.push_back( &(rcv.get_tt(n)) );
                vector<vector<vector<sxyz<T>>>*> all_r_data;
                all_r_data.push_back( &(r_data[n]) );
                for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
                    all_tt.push_back( &(reflectors[nr].get_tt(n)) );
                    all_r_data.push_back( &(rfl_r_data[nr][n]) );
                }
                
                g->raytrace(src[n].get_coord(), src[n].get_t0(), all_rcv,
                            all_tt, all_r_data, 0);
                
                for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
                    g->raytrace(reflectors[nr].get_coord(),
                                reflectors[nr].get_tt(n), rcv.get_coord(),
                                rcv.get_tt(n,nr+1), rfl2_r_data[nr][n], 0);
                }
			}
			
			std::for_each(threads.begin(),threads.end(),
						  std::mem_fn(&std::thread::join));
		}
	} else {
		if ( num_threads == 1 ) {
			for ( size_t n=0; n<src.size(); ++n ) {
				
				vector<vector<T>*> all_tt;
				all_tt.push_back( &(rcv.get_tt(n)) );
				for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
					all_tt.push_back( &(reflectors[nr].get_tt(n)) );
				}
				
				g->raytrace(src[n].get_coord(), src[n].get_t0(), all_rcv,
							all_tt);
				
                //				if ( par.saveGridTT ) {
                //                    //  will overwrite if nsrc>1
                //                    string filename = par.basename+"_all_tt.dat";
                //                    g->saveTT(filename, 0);
                //                }
				
				for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
					g->raytrace(reflectors[nr].get_coord(),
								reflectors[nr].get_tt(n), rcv.get_coord(),
								rcv.get_tt(n,nr+1));
				}
			}
		} else {
			// threaded jobs
			
			vector<thread> threads(num_threads-1);
			size_t blk_start = 0;
			for ( size_t i=0; i<num_threads-1; ++i ) {
				
				size_t blk_end = blk_start + blk_size;
				
				threads[i]=thread( [&g,&src,&rcv,&all_rcv,&reflectors,
									blk_start,blk_end,i]{
					
					for ( size_t n=blk_start; n<blk_end; ++n ) {
						
						vector<vector<T>*> all_tt;
						all_tt.push_back( &(rcv.get_tt(n)) );
						for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
							all_tt.push_back( &(reflectors[nr].get_tt(n)) );
						}
						
						g->raytrace(src[n].get_coord(), src[n].get_t0(), all_rcv,
									all_tt, i+1);
						
						for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
							g->raytrace(reflectors[nr].get_coord(),
										reflectors[nr].get_tt(n), rcv.get_coord(),
										rcv.get_tt(n,nr+1), i+1);
						}
					}
				});
				
				blk_start = blk_end;
			}
			for ( size_t n=blk_start; n<nTx; ++n ) {
				
				vector<vector<T>*> all_tt;
				all_tt.push_back( &(rcv.get_tt(n)) );
				for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
					all_tt.push_back( &(reflectors[nr].get_tt(n)) );
				}
				
				g->raytrace(src[n].get_coord(), src[n].get_t0(), all_rcv,
                            all_tt, 0);
				
				for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
					g->raytrace(reflectors[nr].get_coord(),
								reflectors[nr].get_tt(n), rcv.get_coord(),
								rcv.get_tt(n,nr+1), 0);
				}
			}
			
			std::for_each(threads.begin(),threads.end(),
						  std::mem_fn(&std::thread::join));
		}
	}
	if ( par.time ) { end = chrono::high_resolution_clock::now(); }
    if ( par.verbose ) cout << "done.\n";
	if ( par.time ) {
		cout << "Time to perform raytracing: "
		<< chrono::duration<double>(end-begin).count() << '\n';
	}
	
	if ( par.saveGridTT ) {
		//  will overwrite if nsrc>1
		//string filename = par.basename+"_all_tt.vtu";
		//g->saveTT(filename, 0, 0, true);
        
		string filename = par.basename+"_all_tt.dat";
		g->saveTT(filename, 0);
	}
    
	
    delete g;
    
    if ( src.size() == 1 ) {
		string filename = par.basename+"_tt.dat";
		
		if ( par.verbose ) cout << "Saving traveltimes in " << filename <<  " ... ";
		rcv.save_tt(filename, 0);
		if ( par.verbose ) cout << "done.\n";
		
		if ( par.saveRaypaths ) {
			filename = par.basename+"_rp.vtp";
			if ( par.verbose ) cout << "Saving raypaths in " << filename <<  " ... ";
			saveRayPaths(filename, r_data[0]);
			if ( par.verbose ) cout << "done.\n";
			
			for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
				
				vector<vector<sxyz<T>>> r_tmp( rcv.get_coord().size() );
				for ( size_t irx=0; irx<rcv.get_coord().size(); ++irx ) {
					
					sxyz<T> pt1 = rfl2_r_data[nr][0][irx][0];
					for ( size_t n=0; n<rfl_r_data[nr][0].size(); ++n ) {
						if ( pt1 == rfl_r_data[nr][0][n].back() ) {
							
							for ( size_t i=0; i<rfl_r_data[nr][0][n].size(); ++i ) {
								r_tmp[irx].push_back( rfl_r_data[nr][0][n][i] );
							}
							for ( size_t i=1; i<rfl2_r_data[nr][0][irx].size(); ++i ) {
								r_tmp[irx].push_back( rfl2_r_data[nr][0][irx][i] );
							}
							break;
						}
					}
				}
				filename = par.basename+"_rp"+to_string(nr+1)+".vtp";
				if ( par.verbose ) cout << "Saving raypaths of reflected waves in " << filename <<  " ... ";
				saveRayPaths(filename, r_tmp);
				if ( par.verbose ) cout << "done.\n";
			}
			
			if ( reflectors.size() > 0 ) {
				filename = par.basename+"_rp.bin";
				ofstream fout;
				fout.open(filename, ios::out | ios::binary);
				fout << r_data.size();
				fout.close();
				
				// TODO complete this...
			}
		}
	} else {
        for ( size_t ns=0; ns<src.size(); ++ns ) {
            
            string srcname = par.srcfiles[ns];
            size_t pos = srcname.rfind("/");
            srcname.erase(0, pos+1);
			pos = srcname.rfind(".");
            size_t len = srcname.length()-pos;
            srcname.erase(pos, len);
            
            string filename = par.basename+"_"+srcname+"_tt.dat";
			
            if ( par.verbose ) cout << "Saving traveltimes in " << filename <<  " ... ";
            rcv.save_tt(filename, ns);
            if ( par.verbose ) cout << "done.\n";
			
            if ( par.saveRaypaths ) {
                filename = par.basename+"_"+srcname+"_rp.vtp";
                if ( par.verbose ) cout << "Saving raypaths in " << filename <<  " ... ";
                saveRayPaths(filename, r_data[ns]);
                if ( par.verbose ) cout << "done.\n";
				
				for ( size_t nr=0; nr<reflectors.size(); ++nr ) {
					
					vector<vector<sxyz<T>>> r_tmp( rcv.get_coord().size() );
					for ( size_t irx=0; irx<rcv.get_coord().size(); ++irx ) {
						
						sxyz<T> pt1 = rfl2_r_data[nr][ns][irx][0];
						for ( size_t n=0; n<rfl_r_data[nr][ns].size(); ++n ) {
							if ( pt1 == rfl_r_data[nr][ns][n].back() ) {
								
								for ( size_t i=0; i<rfl_r_data[nr][ns][n].size(); ++i ) {
									r_tmp[irx].push_back( rfl_r_data[nr][ns][n][i] );
								}
								for ( size_t i=1; i<rfl2_r_data[nr][ns][irx].size(); ++i ) {
									r_tmp[irx].push_back( rfl2_r_data[nr][ns][irx][i] );
								}
								break;
							}
						}
					}
					filename = par.basename+"_"+srcname+"_rp"+to_string(nr+1)+".vtp";
					if ( par.verbose ) cout << "Saving raypaths of reflected waves in " << filename <<  " ... ";
					saveRayPaths(filename, r_tmp);
					if ( par.verbose ) cout << "done.\n";
				}
            }
			if ( par.verbose ) cout << '\n';
        }
		
		if ( par.saveRaypaths && reflectors.size() > 0 ) {
			string filename = par.basename+"_rp.bin";
			ofstream fout;
			fout.open(filename, ios::out | ios::binary);
            if ( !fout ) {
                std::cerr << "Cannot open file " << filename << " for writing.\n";
                exit(1);
            }
            
            if ( par.verbose ) cout << "Saving global raypath data in " << filename << " ... ";
			size_t size = r_data.size();
			fout.write((char*)&size,sizeof(size_t));
			for ( size_t n=0; n<r_data.size(); ++n ) {
				size = r_data[n].size();
				fout.write((char*)&size,sizeof(size_t));
				for ( size_t nr=0; nr<r_data[n].size(); ++nr ) {
					size = r_data[n][nr].size();
					fout.write((char*)&size,sizeof(size_t));
					fout.write((char*)r_data[n][nr].data(),
							   sizeof(sxyz<T>) * size);
				}
			}
			
			size = rfl_r_data.size();
			fout.write((char*)&size,sizeof(size_t));
			for ( size_t r=0; r<rfl_r_data.size(); ++r ) {
				size = rfl_r_data[r].size();
				fout.write((char*)&size,sizeof(size_t));
				for ( size_t n=0; n<rfl_r_data[r].size(); ++n ) {
					size = rfl_r_data[r][n].size();
					fout.write((char*)&size,sizeof(size_t));
					for ( size_t nr=0; nr<rfl_r_data[r][n].size(); ++nr ) {
						size = rfl_r_data[r][n][nr].size();
						fout.write((char*)&size,sizeof(size_t));
						fout.write((char*)rfl_r_data[r][n][nr].data(),
								   sizeof(sxyz<T>) * size);
					}
				}
			}
			
			size = rfl2_r_data.size();
			fout.write((char*)&size,sizeof(size_t));
			for ( size_t r=0; r<rfl2_r_data.size(); ++r ) {
				size = rfl2_r_data[r].size();
				fout.write((char*)&size,sizeof(size_t));
				for ( size_t n=0; n<rfl2_r_data[r].size(); ++n ) {
					size = rfl2_r_data[r][n].size();
					fout.write((char*)&size,sizeof(size_t));
					for ( size_t nr=0; nr<rfl2_r_data[r][n].size(); ++nr ) {
						size = rfl2_r_data[r][n][nr].size();
						fout.write((char*)&size,sizeof(size_t));
						fout.write((char*)rfl2_r_data[r][n][nr].data(),
								   sizeof(sxyz<T>) * size);
					}
				}
			}
			
			fout.close();
            if ( par.verbose ) cout << "done.\n";
		}
    }
    
    if ( par.verbose ) cout << "Normal termination of program.\n";
	return 0;
}



int main(int argc, char * argv[])
{
	
    input_parameters par;
    
    string fname = parse_input(argc, argv, par);
    
    if ( par.verbose ) {
        cout << "*** Program ttcr3d ***\n\n"
        << "Raytracing in 3D media.\n";
    }
    get_params(fname, par);
	
    if ( par.verbose ) {
        switch (par.method) {
            case SHORTEST_PATH:
                cout << "Shortest path method selected.\n";
                break;
            case FAST_SWEEPING:
                cout << "Fast sweeping method selected.\n";
                break;
            case FAST_MARCHING:
                cout << "Fast marching method selected.\n";
                break;
            default:
                break;
        }
    }
    
    if ( par.singlePrecision ) {
        return body<float>(par);
    } else {
        return body<double>(par);
    }
    
}

